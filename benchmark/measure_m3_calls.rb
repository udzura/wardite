# frozen_string_literal: true

require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"

# All four loops have the same control flow and increment by one. Table calls
# add a selector, and host calls use the same one-argument ABI in both paths.
calls = {
  "direct_defined" => "call $defined",
  "direct_host" => "call $host",
  "indirect_defined" => "i32.const 0 call_indirect (type $increment)",
  "indirect_host" => "i32.const 1 call_indirect (type $increment)"
}
loops = calls.map do |name, call|
  <<~WAT
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
  WAT
end
wat = <<~WAT
  (module
    (type $increment (func (param i32) (result i32)))
    (import "env" "increment" (func $host (type $increment)))
    (func $defined (type $increment) local.get 0 i32.const 1 i32.add)
    (table 2 funcref)
    (elem (i32.const 0) func $defined $host)
    #{loops.join})
WAT

root = File.expand_path("..", __dir__)
worker = File.join(__dir__, "m3_call_worker.rb")
rounds = Integer(ENV.fetch("ROUNDS", "100000"))
runs = Integer(ENV.fetch("RUNS", "7"))
warmups = Integer(ENV.fetch("WARMUPS", "2"))
abort "invalid rounds, runs or warmups" unless rounds.between?(0, 0x7fffffff) && runs > 0 && warmups >= 0
checksum = (rounds + 123) & 0xffffffff

def capture!(*command)
  out, err, status = Open3.capture3(*command)
  abort "#{command.inspect}\n#{out}#{err}" unless status.success?
  out
end

def stats(samples)
  sorted = samples.sort
  median = (sorted.fetch((sorted.size - 1) / 2) + sorted.fetch(sorted.size / 2)) / 2
  [median, sorted.first, sorted.last].map { |seconds| format("%.3f", seconds * 1000) }
end

Dir.mktmpdir("wardite-m3-bench") do |dir|
  source = File.join(dir, "calls.wat")
  binary = File.join(dir, "calls.wasm")
  native = File.join(dir, "m3-worker")
  File.write(source, wat)
  capture!("wasm-tools", "parse", source, "-o", binary)
  compiler = Shellwords.split(ENV.fetch("SPINEL", "spinel"))
  flags = Shellwords.split(ENV.fetch("SPINELFLAGS", "-O2"))
  capture!(*compiler, "-I#{root}/lib", "--strict-require", *flags, worker, "-o", native)
  runners = {
    "CRuby" => [RbConfig.ruby, "--disable-yjit", "-I#{root}/lib", worker],
    "Spinel" => [native]
  }

  puts "runtime,case,rounds,checksum,load_median_ms,load_min_ms,load_max_ms,execute_median_ms,execute_min_ms,execute_max_ms"
  runners.each do |runtime, command|
    samples = calls.keys.to_h { |name| [name, []] }
    (runs + warmups).times do |iteration|
      calls.keys.rotate(iteration).each do |name|
        load, execute, actual = capture!(*command, binary, name, rounds.to_s).strip.split(",")
        abort "checksum mismatch for #{runtime}/#{name}: #{actual}" unless Integer(actual) == checksum
        samples.fetch(name) << [Float(load), Float(execute)] if iteration >= warmups
      end
    end
    samples.each do |name, observations|
      load, execute = observations.transpose
      puts [runtime, name, rounds, checksum, *stats(load), *stats(execute)].join(",")
    end
  end
end
