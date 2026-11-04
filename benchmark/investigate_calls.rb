# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "open3"
require "rbconfig"
require "shellwords"

Dir.chdir(File.expand_path("..", __dir__))
$stdout.sync = true
root = Dir.pwd
output = File.expand_path("build/benchmark/call-cost")
FileUtils.mkdir_p(output)
rounds = Integer(ARGV.fetch(0, "1000000"), 10)
seed = Integer(ARGV.fetch(1, "123"), 10)
runs = Integer(ENV.fetch("RUNS", "7"))
warmups = Integer(ENV.fetch("WARMUPS", "2"))
abort "invalid inputs" unless (0..0x7fffffff).cover?(rounds) && (0..0xffffffff).cover?(seed) && runs > 1 && warmups >= 0
compiler = Shellwords.split(ENV.fetch("SPINEL", "spinel"))
flags = Shellwords.split(ENV.fetch("SPINELFLAGS", "-O2"))
exports = %w[empty_loop call_identity inline_add_one call_add_one inline_mix call_mix]
variants = %w[full_reset locals_only fresh registers_only metadata_only]
if ENV["EXPORTS"]
  requested = ENV.fetch("EXPORTS").split(",").uniq
  abort "invalid EXPORTS" if requested.empty? || !(requested - exports).empty?
  exports = requested
end
if ENV["VARIANTS"]
  requested = ENV.fetch("VARIANTS").split(",").uniq
  abort "invalid VARIANTS" if requested.empty? || !(requested - variants).empty?
  variants = requested
end
version, status = Open3.capture2e(*compiler, "--version")
abort version unless status.success?

def run!(command, log)
  abort "Failed: #{command.inspect}; see #{log}" unless system(*command, out: log, err: [:child, :out])
end

def replace_once(source, before, after)
  raise "Experimental patch no longer matches current VM" unless source.scan(before).size == 1
  source.sub(before, after)
end

def expected(export, rounds, seed)
  case export
  when "empty_loop", "call_identity" then seed
  when "inline_add_one", "call_add_one" then (seed + rounds) % (2**32)
  else
    x = seed
    rounds.times do
      x ^= x / 8192
      x = (x * 1664525 + 1013904223) % (2**32)
      x = (x ^ (x * 128)) % (2**32)
    end
    x
  end
end

def measure(command, checksum, env = {})
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  stdout, stderr, status = Open3.capture3(env, *command)
  e2e = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  fields = stdout.lines.first.to_s.strip.split(",")
  abort "Checksum failure: #{command.inspect}\n#{stdout}\n#{stderr}" unless status.success? && fields.size == 4 && Integer(fields[3]) == checksum
  {e2e: e2e, load: Float(fields[0]), translate: Float(fields[1]), execute: Float(fields[2]),
    metrics: stdout.lines[1]&.strip, stderr: stderr}
end

def stats(values)
  mean = values.sum / values.size
  variance = values.sum { |value| (value - mean)**2 } / (values.size - 1)
  {mean: mean, sd: Math.sqrt(variance), min: values.min, max: values.max}
end

# Build an auditable fixture from the unchanged acceptance benchmark, replacing
# only the loop body for the differential controls. No calls are inlined by MIR.
mix = File.read("benchmark/i32_mix.wat")
loop_function = mix[/  \(func \(export "call_mix"\).*?(?=\n\)\s*\z)/m] || raise("fixture changed")
call = "        local.get $x\n        call $mix\n        local.set $x"
identity = loop_function.sub('export "call_mix"', 'export "call_identity"').sub("call $mix", "call $identity")
add = loop_function.sub('export "call_mix"', 'export "call_add_one"').sub("call $mix", "call $add_one")
empty = replace_once(loop_function.sub('export "call_mix"', 'export "empty_loop"'), call, "")
inline_add = add.sub('export "call_add_one"', 'export "inline_add_one"').sub("call $add_one", "i32.const 1\n        i32.add")
helpers = "  (func $identity (param i32) (result i32) local.get 0)\n" \
  "  (func $add_one (param i32) (result i32) local.get 0 i32.const 1 i32.add)\n"
wat = "#{mix.rstrip[0...-1]}\n#{helpers}\n#{[empty, identity, inline_add, add].join("\n\n")}\n)\n"
File.write("#{output}/call_cost.wat", wat)
wasm = "#{output}/call_cost.wasm"
run!(["wasm-tools", "parse", "#{output}/call_cost.wat", "-o", wasm], "#{output}/wat-build.log")

ir_source = File.read("lib/wardite/efflorescence/ir.rb")
# Keep the current constructor, validator, MIR and entry point identical. The
# baseline differs only in the body of Frame#reset, reconstructed in a copy.
local_reset = "index = @local_start\n        while index < @local_end\n          @registers[index] = 0"
full_reset = "index = 0\n        while index < @function.register_count\n          @registers[index] = @function.initial_value(index)"
full_ir_source = replace_once(ir_source, local_reset, full_reset)
workers = {}
variants.each do |variant|
  directory = "#{output}/#{variant}"
  FileUtils.mkdir_p(directory)
  library = "#{root}/lib"
  unless variant == "locals_only"
    FileUtils.rm_rf("#{directory}/lib")
    FileUtils.cp_r("lib", "#{directory}/lib")
    library = "#{directory}/lib"
    source = variant == "metadata_only" ? ir_source.dup : full_ir_source.dup
    if variant == "registers_only"
      # Reuse the inactive frame's Integer array, but allocate a new Frame on
      # every acquisition. Both this and pooled still reset every register.
      source = replace_once(source, "def initialize(function, return_register)\n", "def initialize(function, return_register, registers = nil)\n")
      source = replace_once(source, "@registers = function.initial_registers.dup", "@registers = registers || function.initial_registers.dup")
      # A new Frame backed by an old array still needs the baseline reset.
      constructor_end = "@local_end = @local_start + function.local_count\n        @return_register = return_register\n        @pc = 0"
      source = replace_once(source, constructor_end, "#{constructor_end}\n        reset(return_register) if registers")
      source = replace_once(source, "frame.reset(destination)\n            return frame", "@created += 1\n            return Frame.new(@function, destination, frame.registers)")
    elsif variant == "metadata_only"
      # A deliberately restricted upper bound: the three leaf callees in this
      # fixture have no non-parameter locals and read no temporary before writing
      # it. Initial constants survive reuse; arguments are overwritten by CALL.
      source = replace_once(source, "frame.reset(destination)\n            return frame", "frame.reset_metadata(destination)\n            return frame")
      marker = "    # An invocation owns its pools. Active recursive frames never enter the"
      method = <<~RUBY
        # @rbs return_register: Integer
        # @rbs return: void
        def reset_metadata(return_register)
          raise \"benchmark requires zero non-parameter locals\" unless @function.local_count == 0
          @return_register = return_register
          @pc = 0
        end
      RUBY
      # Insert into Frame, immediately before its closing end.
      before = "    end\n\n#{marker}"
      source = replace_once(source, before, "#{method.lines.map { |line| "      #{line}" }.join}    end\n\n#{marker}")
    end
    File.write("#{library}/wardite/efflorescence/ir.rb", source)
  end
  worker = "#{directory}/worker"
  run!([*compiler, "-I#{library}", "--strict-require", *flags, "benchmark/call_cost_worker.rb", "-o", worker], "#{directory}/build.log")
  workers[variant] = {binary: worker, library: library, disabled: variant == "fresh" ? "frames" : ""}
  puts "Built #{variant}"
end

# Confirm the current engine, old Stack VM and independent arithmetic agree on
# the controls and i32 boundaries before measuring any variant. Each native
# variant is also checked at zero/one/many iterations with negative-bit seeds.
validation = [[0, 0], [0, 123], [1, 0xffffffff], [10, 123], [1000, 0xffffffff]]
validation_worker = "#{output}/validate.rb"
File.write(validation_worker, <<~RUBY)
  require "wardite"
  wasm, rounds, seed = ARGV
  instance = File.open(wasm, "rb") { |file| Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false) }
  #{exports.inspect}.each { |name| puts "\#{name},\#{instance.runtime.call(name, [rounds.to_i, seed.to_i]).value}" }
RUBY
validation.each do |count, initial|
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", validation_worker, wasm, count.to_s, initial.to_s)
  abort stderr unless status.success?
  stdout.each_line do |line|
    name, value = line.strip.split(",")
    raise "Old VM mismatch" unless Integer(value) == expected(name, count, initial)
  end
  workers.each_value do |worker|
    exports.each do |name|
      command = [worker[:binary], wasm, name, count.to_s, initial.to_s, worker[:disabled]]
      measure(command, expected(name, count, initial))
    end
  end
end
checksums = exports.to_h { |name| [name, expected(name, rounds, seed)] }
puts "All variants, old VM and reference agree on boundary/control cases."

rows = exports.flat_map do |name|
  workers.map do |variant, worker|
    command = [worker[:binary], wasm, name, rounds.to_s, seed.to_s, worker[:disabled]]
    counters = measure([*command, "metrics"], checksums.fetch(name))
    {export: name, variant: variant, command: command, metrics: counters[:metrics], samples: []}
  end
end

# Round-robin all cases, rotating and reversing order. Process start, load and
# translation are recorded separately; execution is the primary comparison.
(warmups + runs).times do |iteration|
  ordered = rows.rotate(iteration * 5)
  ordered = ordered.reverse if iteration.odd?
  ordered.each do |row|
    sample = measure(row[:command], checksums.fetch(row[:export]))
    row[:samples] << sample.reject { |key, _| %i[metrics stderr].include?(key) } if iteration >= warmups
  end
  puts "Completed #{iteration < warmups ? "warmup" : "sample"} #{iteration < warmups ? iteration + 1 : iteration - warmups + 1}"
end

rows.each do |row|
  row[:statistics_ms] = %i[e2e load translate execute].to_h do |phase|
    [phase, stats(row[:samples].map { |sample| sample.fetch(phase) * 1000 })]
  end
  stat = row[:statistics_ms][:execute]
  puts "%s/%s: %.3f ± %.3f ms (%s)" % [row[:export], row[:variant], stat[:mean], stat[:sd], row[:metrics]]
end

# Allocation reports are deliberately outside timing. Compare equal binaries
# at zero and nonzero rounds to remove most loader/translation allocations.
allocations = []
workers.each do |variant, worker|
  %w[call_identity call_mix].each do |name|
    [0, 10000].each do |count|
      report = "#{output}/#{variant}/#{name}-#{count}.alloc.folded"
      command = [worker[:binary], wasm, name, count.to_s, seed.to_s, worker[:disabled]]
      measure(command, expected(name, count, seed), {"SPINEL_ALLOC_REPORT" => report})
      counts = File.readlines(report).filter_map do |line|
        match = line.match(/^alloc;(.+) (\d+)$/)
        [match[1], Integer(match[2])] if match
      end.to_h
      allocations << {variant: variant, export: name, rounds: count,
        frames: counts.fetch("Wardite::Efflorescence::Frame"),
        no_scan: counts.fetch("(no-scan)"), total: counts.values.sum}
    end
  end
end

commit, status = Open3.capture2("git", "rev-parse", "HEAD")
abort "git revision unavailable" unless status.success?
report = {rounds: rounds, seed: seed, checksums: checksums, runs: runs, warmups: warmups,
  ruby: RUBY_DESCRIPTION, spinel: version.strip, spinel_flags: flags,
  source_files_sha256: Dir["lib/**/*.rb"].sort.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] },
  binary_sha256: workers.to_h { |name, worker| [name, Digest::SHA256.file(worker[:binary]).hexdigest] },
  source_commit: commit.strip, allocations: allocations,
  note: "full_reset restores the old reset loop in a copy; locals_only is production; metadata_only is fixture-specific",
  results: rows}
File.write("#{output}/results.json", JSON.pretty_generate(report) + "\n")
puts "Saved #{output}/results.json"
