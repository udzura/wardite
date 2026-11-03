# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"

Dir.chdir(File.expand_path("..", __dir__))
rounds = Integer(ARGV.fetch(0, "100000"), 10)
seed = Integer(ARGV.fetch(1, "123"), 10)
abort "rounds must be 0..2147483647; seed must be 0..4294967295" unless
  (0..0x7fffffff).cover?(rounds) && (0..0xffffffff).cover?(seed)
runs = Integer(ENV.fetch("RUNS", "5"))
warmups = Integer(ENV.fetch("WARMUPS", "2"))
abort "RUNS must be positive; WARMUPS must be nonnegative" unless runs > 0 && warmups >= 0
FileUtils.mkdir_p("build/benchmark")
wasm = "build/benchmark/i32_mix.wasm"
abort "WAT compilation failed" unless system("wasm-tools", "parse", "benchmark/i32_mix.wat", "-o", wasm)
abort "Spinel CLI build failed" unless system("make", "spinel")
compiler = Shellwords.split(ENV.fetch("SPINEL", "spinel"))
flags = Shellwords.split(ENV.fetch("SPINELFLAGS", "-O2"))
abort "Spinel phase runner build failed" unless system(*compiler, "-I", "lib", "--strict-require", *flags,
  "benchmark/engine_phases.rb", "-o", "build/benchmark/engine_phases")

def reference(rounds, seed)
  x = seed % (2**32)
  rounds.times do
    x ^= x / (2**13)
    x = (x * 1664525 + 1013904223) % (2**32)
    x = (x ^ (x * (2**7))) % (2**32)
  end
  x
end

runtimes = {
  "CRuby" => [RbConfig.ruby, "--disable-yjit", "-Ilib"],
  "Spinel" => ["./build/wardite"]
}
_output, yjit = Open3.capture2e(RbConfig.ruby, "--yjit", "-e",
  "exit(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? 0 : 1)")
runtimes["CRuby + YJIT"] = [RbConfig.ruby, "--yjit", "-Ilib"] if yjit.success?

def cli_command(runner, engine, export, wasm, rounds, seed)
  command = runner.dup
  command << "exe/wardite" unless runner.first == "./build/wardite"
  command << "--new-engine" if engine == "efflorescence"
  command + ["--no-wasi", "--invoke", export, "--", wasm, rounds.to_s, seed.to_s]
end

def checked_cli(command, checksum)
  signed = checksum >= 0x80000000 ? checksum - 0x100000000 : checksum
  stdout, stderr, status = Open3.capture3(*command)
  abort "Checksum failure: #{command.inspect}: #{stdout.inspect} #{stderr.inspect}" unless
    status.success? && stdout.empty? && stderr == "return value: I32(#{signed})\n"
end

def checked_phases(command, checksum)
  stdout, stderr, status = Open3.capture3(*command)
  fields = stdout.strip.split(",")
  abort "Phase runner failed: #{command.inspect}: #{stdout.inspect} #{stderr.inspect}" unless
    status.success? && fields.size == 4 && Integer(fields[3]) == checksum
  fields.first(3).map { |value| Float(value) }
end

# Gate ALL performance measurement on the complete acceptance matrix.
cases = [[0, 0], [0, 123], [1, 0], [1, 123], [10, 123], [1000, 123],
         [1000, 0xffffffff], [100000, 123], [rounds, seed]].uniq
cases.each do |count, input|
  expected = reference(count, input)
  runtimes.each_value do |runner|
    %w[stack efflorescence].each do |engine|
      %w[inline_mix call_mix].each do |export|
        checked_cli(cli_command(runner, engine, export, wasm, count, input), expected)
      end
    end
  end
end
phase_runners = runtimes.transform_values do |runner|
  runner.first == "./build/wardite" ? ["./build/benchmark/engine_phases"] : runner + ["benchmark/engine_phases.rb"]
end
phase_runners.each_value do |runner|
  %w[stack efflorescence].each do |engine|
    %w[inline_mix call_mix].each do |export|
      checked_phases(runner + [wasm, engine, export, rounds.to_s, seed.to_s], reference(rounds, seed))
    end
  end
end
puts "All #{cases.size} input cases match the independent reference on both engines and all runtimes."

expected = reference(rounds, seed)
results = []
%w[inline_mix call_mix].each do |export|
  runtimes.each do |name, runner|
    %w[stack efflorescence].each do |engine|
      command = cli_command(runner, engine, export, wasm, rounds, seed)
      phase_runner = phase_runners.fetch(name)
      phase_command = phase_runner + [wasm, engine, export, rounds.to_s, seed.to_s]
      samples = []
      (warmups + runs).times do |iteration|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        checked_cli(command, expected)
        e2e = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        phases = checked_phases(phase_command, expected)
        samples << [e2e, *phases] if iteration >= warmups
      end
      means = (0...4).map { |i| samples.sum { |sample| sample[i] } / runs }
      row = {runtime: name, engine: engine, export: export, checksum: expected,
             e2e_ms: means[0] * 1000, load_ms: means[1] * 1000,
             translate_ms: means[2] * 1000, execute_ms: means[3] * 1000, samples_seconds: samples}
      results << row
      puts "%s / %s / %s: e2e %.2f ms; load %.3f ms; MIR %.3f ms; execute %.2f ms" %
        [name, engine, export, row[:e2e_ms], row[:load_ms], row[:translate_ms], row[:execute_ms]]
    end
  end
end
File.write("build/benchmark/engines.json", JSON.pretty_generate({rounds: rounds, seed: seed,
  runs: runs, warmups: warmups, ruby: RUBY_DESCRIPTION, results: results}))
puts "Saved build/benchmark/engines.json (rounds=#{rounds}, seed=#{seed}, checksum=#{expected})."
