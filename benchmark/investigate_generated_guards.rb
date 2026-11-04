# frozen_string_literal: true

# All experiments live in copied sources/generated C under build/. Production
# Ruby, the installed Spinel compiler and its collector are never patched.
require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"

Dir.chdir(File.expand_path("..", __dir__))
$stdout.sync = true
output = File.expand_path(ENV.fetch("GUARDS_DIR", "build/benchmark/generated-guards"))
abort "GUARDS_DIR must be inside build/" unless output.start_with?(File.expand_path("build") + "/")
FileUtils.mkdir_p(output)
rounds = Integer(ARGV.fetch(0, "1000000"))
seed = Integer(ARGV.fetch(1, "123"))
runs = Integer(ENV.fetch("RUNS", "3"))
warmups = Integer(ENV.fetch("WARMUPS", "1"))
abort "invalid inputs" unless (0..0x7fffffff).cover?(rounds) && (0..0xffffffff).cover?(seed) && runs > 1 && warmups >= 0
variants = %w[baseline guarded_index while_loop while_guarded c_root_elision while_c_root_elision]
if ENV["VARIANTS"]
  requested = ENV.fetch("VARIANTS").split(",").uniq
  abort "invalid VARIANTS (include baseline)" unless requested.include?("baseline") && (requested - variants).empty?
  variants = requested
end
compiler = Shellwords.split(ENV.fetch("SPINEL", "spinel"))
cc = Shellwords.split(ENV.fetch("CC", "clang"))
native_flags = ["-O2"]
native_flags += %w[-g -fno-omit-frame-pointer] if ENV["PROFILE"] == "1"
with_cli = ENV["CLI"] == "1"
version, status = Open3.capture2e(*compiler, "--version")
abort version unless status.success?
cc_version, status = Open3.capture2e(*cc, "--version")
abort cc_version unless status.success?
commit, status = Open3.capture2e("git", "rev-parse", "HEAD")
abort commit unless status.success?

def run!(command, log)
  abort "Failed: #{command.inspect}; see #{log}" unless system(*command, out: log, err: [:child, :out])
end

def vm_body(source)
  source[/^static [^\n]+sp_(?:Wardite__Efflorescence__)?VM_execute_flat\([^;\n]*\) \{.*?(?=^static |\z)/m] || raise("missing execute_flat C body")
end

def c_metrics(source)
  body = vm_body(source)
  loop_prefix = body[/(?:for \(;;\)|while \(1\)) \{\n(.*?)^\s*lv_opcode\w* = \(\{/m, 1] || ""
  {bytes: body.bytesize, temporary_roots: body.scan(/SP_GC_ROOT\(/).size,
    instruction_roots: body.scan(/sp_IntArray \*(_t\d+) = lv_instructions; SP_GC_ROOT\(\1\);/).size,
    rooted_instructions: !!body.match(/SP_GC_ENTRY_PTR\(lv_instructions\)/),
    root_frames: body.scan(/SP_GC_ROOT_FRAME\(/).size, setjmps: body.scan(/\bsetjmp\(/).size,
    volatile_lines: body.lines.count { |line| line.match?(/\bvolatile\b/) },
    boxed_local_names: body.scan(/^\s*(?:volatile\s+)?sp_RbVal(?:\s+volatile)?\s+(lv_\w+)\s*=/).flatten,
    iteration_resets: loop_prefix.lines.count { |line| line.match?(/^\s*lv_\w+ = (?:0|NULL|sp_box_nil\(\)|sp_oint_nil\(\));\s*$/) },
    generic_array_ops: body.scan(/sp_PolyArray_(?:get|set|push|pop|new)/).size,
    polymorphic_calls: body.scan(/sp_pd_[a-f0-9]+\(/).size}
end

def reference(rounds, seed)
  x = seed
  rounds.times do
    x ^= x / 8192
    x = (x * 1664525 + 1013904223) % (2**32)
    x = (x ^ (x * 128)) % (2**32)
  end
  x
end

def sample(command, expected)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  out, err, status = Open3.capture3(*command)
  e2e = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  fields = out.lines.first.to_s.strip.split(",")
  abort "Checksum mismatch: #{command.inspect}\n#{out}#{err}" unless status.success? && fields.size == 4 && Integer(fields[3]) == expected
  {worker_e2e: e2e, load: Float(fields[0]), translate: Float(fields[1]), execute: Float(fields[2]), metrics: out.lines[1]&.strip}
end

def cli_sample(command, expected)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  out, err, status = Open3.capture3(*command)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  signed = expected >= 0x80000000 ? expected - 0x100000000 : expected
  abort "CLI checksum mismatch: #{command.inspect}\n#{out}#{err}" unless status.success? && out.empty? && err == "return value: I32(#{signed})\n"
  elapsed
end

def statistics(values)
  mean = values.sum / values.size
  {mean: mean, sd: Math.sqrt(values.sum { |x| (x - mean)**2 } / (values.size - 1)), min: values.min, max: values.max}
end

wasm = "#{output}/i32_mix.wasm"
run!(["wasm-tools", "parse", "benchmark/i32_mix.wat", "-o", wasm], "#{output}/wat.log")
original = File.read("lib/wardite/efflorescence/vm.rb")
snapshots = {}
variants.each do |variant|
  directory = "#{output}/#{variant}"
  FileUtils.mkdir_p(directory)
  %w[lib exe benchmark].each { |name| FileUtils.rm_rf("#{directory}/#{name}") }
  FileUtils.cp_r(%w[lib exe], directory)
  FileUtils.mkdir_p("#{directory}/benchmark")
  FileUtils.cp("benchmark/call_cost_worker.rb", "#{directory}/benchmark")
  prefix, flat = original.split("      def execute_flat(frame, pools)\n", 2)
  raise "VM shape changed" unless flat && flat.scan(/^        (?:loop do|while true)\n/).size == 1
  # Reconstruct both spellings even after production adopts the while loop.
  use_while = %w[while_loop while_guarded while_c_root_elision].include?(variant)
  loop_header = use_while ? "while true" : "loop do"
  flat = flat.sub(/^        (?:loop do|while true)\n/, "        #{loop_header}\n")
  unless use_while
    flat = flat.sub("        # Steep treats while as possibly nil; execution always returns or raises.\n" \
      "        raise Wardite::EvalError, \"Efflorescence: MIR execution ended without RETURN\"\n", "")
  end
  if %w[guarded_index while_guarded].include?(variant)
    count = 0
    flat = flat.gsub(/instructions\.fetch\((pc(?: \+ \d+)?)\)/) do
      count += 1
      "(instructions[#{$1}] || raise(::IndexError, \"Efflorescence: invalid MIR word\"))"
    end
    raise "missing instruction fetches" unless count > 20
  end
  File.write("#{directory}/lib/wardite/efflorescence/vm.rb", "#{prefix}      def execute_flat(frame, pools)\n#{flat}")
  artifacts = {}
  entries = {"worker" => "benchmark/call_cost_worker.rb"}
  entries["wardite"] = "exe/wardite" if with_cli
  entries.each do |binary, entry|
    generated = "#{directory}/#{binary}.c"
    command = [*compiler, "-I#{directory}/lib", "--strict-require", "-O2", "--no-line-map", "-c",
      "#{directory}/#{entry}", "-o", generated, "--print-build"]
    out, err, status = Open3.capture3(*command)
    File.write("#{directory}/#{binary}-spinel.log", err)
    abort "Spinel failed: #{variant}/#{binary}" unless status.success?
    File.write("#{directory}/#{binary}-ingredients.txt", out)
    ingredients = out.lines.map { |line| line.strip.split(" ", 2) }
    known = %w[cflag include define source link runtime lib]
    raise "unexpected build ingredients" unless ingredients.all? { |kind, value| known.include?(kind) && value } && ingredients.include?(["source", generated])
    c_source = File.read(generated)
    before = c_metrics(c_source)
    if %w[c_root_elision while_c_root_elision].include?(variant)
      body = vm_body(c_source)
      raise "instruction variable is not a function-scoped root" unless before[:rooted_instructions]
      # The index must be the local PC or its checked integer addition. An
      # arbitrary Ruby argument can allocate or overwrite the receiver's slot.
      fetch_root = /(sp_IntArray \*(_t\d+) = lv_instructions; )SP_GC_ROOT\(\2\);( sp_int _t\d+ = (?:lv_pc|sp_int_add\(lv_pc, [123]LL\));)/
      raise "unrecognized fetch argument" unless body.scan(fetch_root).size == before[:instruction_roots]
      changed = body.gsub(fetch_root, '\1\3')
      raise "no redundant fetch roots" unless before[:instruction_roots] > 20 && changed != body
      c_source = c_source.sub(body, changed)
      File.write(generated, c_source)
    end
    flags = ingredients.filter_map { |kind, value| kind == "include" ? "-I#{value}" : (%w[cflag define].include?(kind) ? value : nil) }
    links = ingredients.filter_map { |kind, value| value if %w[link runtime lib].include?(kind) }
    object = "#{directory}/#{binary}.o"
    build = [*cc, *native_flags, *flags, "-c", generated, "-o", object]
    link = [*cc, *(ENV["PROFILE"] == "1" ? ["-g"] : []), object, *links, "-o", "#{directory}/#{binary}"]
    File.write("#{directory}/#{binary}-compile.json", JSON.pretty_generate({compile: build, link: link}) + "\n")
    run!(build, "#{directory}/#{binary}-clang.log")
    run!(link, "#{directory}/#{binary}-link.log")
    if ENV["PROFILE"] == "1" && RUBY_PLATFORM.include?("darwin")
      FileUtils.rm_rf("#{directory}/#{binary}.dSYM")
      run!(["dsymutil", "#{directory}/#{binary}"], "#{directory}/#{binary}-dsym.log")
    end
    artifacts[binary] = {before: before, after: c_metrics(c_source), c_sha256: Digest::SHA256.file(generated).hexdigest,
      binary_sha256: Digest::SHA256.file("#{directory}/#{binary}").hexdigest, compile_command: build, link_command: link}
  end
  sources = Dir["#{directory}/{lib,exe,benchmark}/**/*"].select { |path| File.file?(path) }.sort.to_h do |path|
    [path.delete_prefix("#{directory}/"), Digest::SHA256.file(path).hexdigest]
  end
  snapshots[variant] = {directory: directory, source_sha256: sources, vm_source: File.read("#{directory}/lib/wardite/efflorescence/vm.rb"), artifacts: artifacts}
  puts "Built #{variant}: #{artifacts.fetch('worker').fetch(:after)}"
end

cases = [["inline_mix", ""], ["call_mix", ""], ["call_mix", "inline"]]
checksum = reference(rounds, seed)
rows = cases.flat_map do |name, disabled|
  variants.map do |variant|
    directory = snapshots.fetch(variant).fetch(:directory)
    worker = ["#{directory}/worker", wasm, name, rounds.to_s, seed.to_s, disabled]
    cli = with_cli ? ["#{directory}/wardite", "--new-engine", "--no-wasi"] : nil
    cli += ["--mir-disable", "inline"] if cli && !disabled.empty?
    cli += ["--invoke", name, "--", wasm, rounds.to_s, seed.to_s] if cli
    metrics = sample([*worker, "metrics"], checksum).fetch(:metrics)
    [[0, 0], [0, 123], [1, 0], [1, 123], [10, 123], [1000, 123], [1000, 0xffffffff], [100000, 123]].each do |n, initial|
      sample(["#{directory}/worker", wasm, name, n.to_s, initial.to_s, disabled], reference(n, initial))
    end
    {export: name, disabled: disabled, variant: variant, worker: worker, cli: cli, metrics: metrics, samples: []}
  end
end
cases.each do |name, disabled|
  counters = rows.select { |row| row[:export] == name && row[:disabled] == disabled }.map { |row| row[:metrics] }.uniq
  abort "MIR metrics differ" unless counters.size == 1
end
puts "All complete acceptance inputs, measured checksums and MIR counters match."
(warmups + runs).times do |iteration|
  order = rows.rotate(iteration * 3)
  order.reverse! if iteration.odd?
  order.each do |row|
    measured = sample(row[:worker], checksum).reject { |key, _| key == :metrics }
    measured[:cli_e2e] = cli_sample(row[:cli], checksum) if row[:cli]
    row[:samples] << measured if iteration >= warmups
  end
  puts "Completed #{iteration < warmups ? 'warmup' : 'sample'} #{iteration < warmups ? iteration + 1 : iteration - warmups + 1}"
end
rows.each do |row|
  row[:statistics_ms] = row[:samples].first.keys.to_h { |phase| [phase, statistics(row[:samples].map { |s| s.fetch(phase) * 1000 })] }
  stats = row[:statistics_ms][:execute]
  puts "%s/%s/%s: %.3f ± %.3f ms" % [row[:variant], row[:export], row[:disabled].empty? ? 'inline-on' : 'inline-off', stats[:mean], stats[:sd]]
  row.delete(:worker)
  row.delete(:cli)
end
snapshots.each_value { |snapshot| snapshot.delete(:directory) }
File.write("#{output}/results.json", JSON.pretty_generate({commit: commit.strip, spinel: version.strip,
  cc: cc_version.lines.first.strip, native_flags: native_flags, rounds: rounds, seed: seed, checksum: checksum,
  fixture: {wat_sha256: Digest::SHA256.file("benchmark/i32_mix.wat").hexdigest, wasm_sha256: Digest::SHA256.file(wasm).hexdigest},
  runs: runs, warmups: warmups, cli: with_cli, snapshots: snapshots, results: rows}) + "\n")
puts "Saved #{output}/results.json"
