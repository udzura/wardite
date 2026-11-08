# frozen_string_literal: true

# Usage: bundle exec ruby -Ilib benchmark/measure_m4.rb /path/to/m3-checkout
require "wardite"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"

root = File.expand_path("..", __dir__)
baseline = File.expand_path(ARGV.fetch(0))
worker = File.join(__dir__, "m3_call_worker.rb")
rounds = Integer(ENV.fetch("ROUNDS", "100000"))
i64_rounds = Integer(ENV.fetch("I64_ROUNDS", "20000"))
runs = Integer(ENV.fetch("RUNS", "7"))
warmups = Integer(ENV.fetch("WARMUPS", "2"))
abort "invalid rounds or runs" unless [rounds, i64_rounds].all? { |n| n.between?(1, 0x7fffffff) } && runs > 0 && warmups >= 0

calls = {
  "direct_defined" => "call $defined",
  "direct_host" => "call $host",
  "indirect_defined" => "i32.const 0 call_indirect (type $increment)",
  "indirect_host" => "i32.const 1 call_indirect (type $increment)"
}
call_wat = <<~WAT
  (module
    (type $increment (func (param i32) (result i32)))
    (import "env" "increment" (func $host (type $increment)))
    (func $defined (type $increment) local.get 0 i32.const 1 i32.add)
    (table 2 funcref)
    (elem (i32.const 0) func $defined $host)
    #{calls.map do |name, call|
      <<~FUNC
        (func (export "#{name}") (param $n i32) (param $sum i32) (result i32)
          block $done
            loop $repeat
              local.get $n i32.eqz br_if $done
              local.get $sum #{call} local.set $sum
              local.get $n i32.const 1 i32.sub local.set $n
              br $repeat
            end
          end
          local.get $sum)
      FUNC
    end.join})
WAT

def capture!(*command)
  output, error, status = Open3.capture3(*command)
  abort "#{command.inspect}\n#{output}#{error}" unless status.success?
  output.strip
end

def stats(samples)
  sorted = samples.sort
  median = (sorted.fetch((sorted.size - 1) / 2) + sorted.fetch(sorted.size / 2)) / 2
  [median, sorted.first, sorted.last].map { |seconds| format("%.3f", seconds * 1000) }
end

def allocation_probe(binary, export, rounds, expected)
  vm = Wardite.new(path: binary, engine: :efflorescence, enable_wasi: false).runtime
  args = [rounds, 123]
  vm.call_unboxed(export, args)
  start = GC.stat(:total_allocated_objects)
  actual = vm.call_unboxed(export, args)
  allocated = GC.stat(:total_allocated_objects) - start
  abort "allocation probe checksum mismatch" unless actual == expected

  boxes = 0
  trace = TracePoint.new(:call) { |event| boxes += 1 if event.defined_class == Wardite::I64 && event.method_id == :initialize }
  trace.enable { vm.call_unboxed(export, args) }
  unboxed = boxes
  trace.enable { vm.call(export, args) }
  boxed = boxes - unboxed
  abort "unexpected I64 allocations for #{export}: unboxed=#{unboxed}, boxed=#{boxed}" unless unboxed == 0 && boxed == 1

  vm = Wardite.new(path: binary, engine: :efflorescence, enable_wasi: false, mir_profile: true).runtime
  abort "profile checksum mismatch" unless vm.call_unboxed(export, args) == expected
  warn "#{export}: allocations=#{allocated}, I64 boxes=#{unboxed} unboxed/#{boxed} boxed, #{vm.metrics.report}"
end

Dir.mktmpdir("wardite-m4-bench") do |dir|
  runners = {}
  compiler = Shellwords.split(ENV.fetch("SPINEL", "spinel"))
  flags = Shellwords.split(ENV.fetch("SPINELFLAGS", "-O2"))
  { "M3" => baseline, "M4" => root }.each do |version, path|
    native = File.join(dir, "#{version}-worker")
    capture!(*compiler, "-I#{path}/lib", "--strict-require", *flags, worker, "-o", native)
    runners[["CRuby", version]] = [RbConfig.ruby, "--disable-yjit", "-I#{path}/lib", worker]
    runners[["Spinel", version]] = [native]
  end

  call_source = File.join(dir, "calls.wat")
  File.write(call_source, call_wat)
  suites = {
    File.join(__dir__, "i32_mix.wat") => [%w[inline_mix call_mix], rounds, false],
    File.join(__dir__, "i32_call_arities.wat") => [%w[empty_loop call_zero call_one call_two call_three call_four], rounds, false],
    call_source => [calls.keys, rounds, false],
    File.join(__dir__, "i64_m4.wat") => [%w[alu division memory mixed_call], i64_rounds, true]
  }

  puts "runtime,version,case,rounds,checksum,load_median_ms,load_min_ms,load_max_ms,execute_median_ms,execute_min_ms,execute_max_ms"
  suites.each do |source, (exports, count, i64)|
    binary = File.join(dir, "input.wasm")
    capture!("wasm-tools", "parse", source, "-o", binary)
    commands = i64 ? runners.select { |(_, version), _| version == "M4" } : runners
    exports.each do |export|
      checksum = if source == call_source
                   (count + 123) % 2**32
                 else
                   result = Integer(capture!("wasmtime", "run", "--invoke", export, binary, count.to_s, "123"))
                   i64 ? result : result % 2**32
                 end
      samples = commands.keys.to_h { |key| [key, []] }
      (runs + warmups).times do |i|
        commands.keys.rotate(i).each do |key|
          load, execute, actual = capture!(*commands.fetch(key), binary, export, count.to_s).split(",")
          abort "#{key}/#{export}: #{checksum} expected, #{actual} actual" unless Integer(actual) == checksum
          samples.fetch(key) << [Float(load), Float(execute)] if i >= warmups
        end
      end
      samples.each do |(runtime, version), observations|
        load, execute = observations.transpose
        puts [runtime, version, export, count, checksum, *stats(load), *stats(execute)].join(",")
      end
      allocation_probe(binary, export, count, checksum) if i64
    end
  end
end
