# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require_relative "../lib/wardite"

Dir.chdir(File.expand_path("..", __dir__))
$stdout.sync = true
rounds = Integer(ARGV.fetch(0, "100000"), 10)
seed = Integer(ARGV.fetch(1, "123"), 10)
abort "invalid rounds or seed" unless (0..0x7fffffff).cover?(rounds) && (0..0xffffffff).cover?(seed)
runs = Integer(ENV.fetch("RUNS", "5"))
warmups = Integer(ENV.fetch("WARMUPS", "2"))
abort "invalid sample counts" unless runs > 0 && warmups >= 0
FileUtils.mkdir_p("build/benchmark")
wasm = "build/benchmark/i32_mix.wasm"
abort "WAT compilation failed" unless system("wasm-tools", "parse", "benchmark/i32_mix.wat", "-o", wasm)
abort "Spinel build failed" unless system("make", "spinel", out: "build/benchmark/phase2-build.log", err: [:child, :out])
compiler = Shellwords.split(ENV.fetch("SPINEL", "spinel"))
flags = Shellwords.split(ENV.fetch("SPINELFLAGS", "-O2"))
spinel_version, version_status = Open3.capture2e(*compiler, "--version")
abort "Cannot identify Spinel" unless version_status.success?
abort "Worker build failed" unless system(*compiler, "-I", "lib", "--strict-require", *flags,
  "benchmark/optimization_worker.rb", "-o", "build/benchmark/optimization_worker",
  out: "build/benchmark/phase2-worker-build.log", err: [:child, :out])

def reference(rounds, seed)
  x = seed % (2**32)
  rounds.times do
    x ^= x / 8192
    x = (x * 1664525 + 1013904223) % (2**32)
    x = (x ^ (x * 128)) % (2**32)
  end
  x
end

variants = {"unoptimized" => [:all], "optimized" => []}
if ENV["ABLATIONS"] == "1"
  Wardite::Efflorescence::Configuration::FEATURES.each { |feature| variants["no-#{feature}"] = [feature] }
end
phase1 = ENV["PHASE1_ROOT"]
variants["phase1"] = [] if phase1
runtimes = {"CRuby" => [RbConfig.ruby, "--disable-yjit"], "Spinel" => []}
_output, yjit = Open3.capture2e(RbConfig.ruby, "--yjit", "-e",
  "exit(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? 0 : 1)")
runtimes["YJIT"] = [RbConfig.ruby, "--yjit"] if yjit.success?

def commands(name, runner, variant, disabled, phase1, wasm, export, rounds, seed)
  if variant == "phase1"
    if name == "Spinel"
      cli = [ENV.fetch("PHASE1_BIN", "build/benchmark/phase1-wardite")]
      worker = [ENV.fetch("PHASE1_WORKER", "build/benchmark/phase1-engine-phases")]
    else
      cli = runner + ["-I#{phase1}/lib", "#{phase1}/exe/wardite"]
      worker = runner + ["-I#{phase1}/lib", "#{phase1}/benchmark/engine_phases.rb"]
    end
    worker += [wasm, "efflorescence", export, rounds.to_s, seed.to_s]
  else
    cli = name == "Spinel" ? ["./build/wardite"] : runner + ["-Ilib", "exe/wardite"]
    worker = name == "Spinel" ? ["./build/benchmark/optimization_worker"] : runner + ["-Ilib", "benchmark/optimization_worker.rb"]
    worker += [wasm, export, rounds.to_s, seed.to_s, disabled.join(",")]
    disabled.each { |feature| cli += ["--mir-disable", feature.to_s] }
  end
  [cli + ["--new-engine", "--no-wasi", "--invoke", export, "--", wasm, rounds.to_s, seed.to_s], worker]
end

def checked_cli(command, checksum)
  signed = checksum >= 0x80000000 ? checksum - 0x100000000 : checksum
  out, err, status = Open3.capture3(*command)
  abort "CLI checksum mismatch: #{command.inspect}\n#{out}#{err}" unless
    status.success? && out.empty? && err == "return value: I32(#{signed})\n"
end

def checked_worker(command, checksum)
  out, err, status = Open3.capture3(*command)
  values = out.strip.split(",")
  abort "Worker checksum mismatch: #{command.inspect}\n#{out}#{err}" unless
    status.success? && [4, 5].include?(values.size) && Integer(values[3]) == checksum
  [*values.first(3).map { |value| Float(value) }, values[4] ? Integer(values[4]) : nil]
end

# Gate every measured variant/runtime, including the independent Phase 1 build.
checksum = reference(rounds, seed)
matrix = []
runtimes.each do |name, runner|
  variants.each do |variant, disabled|
    %w[inline_mix call_mix].each do |export|
      cli, worker = commands(name, runner, variant, disabled, phase1, wasm, export, rounds, seed)
      checked_cli(cli, checksum)
      checked_worker(worker, checksum)
      matrix << [name, variant, disabled, export, cli, worker]
    end
  end
end
puts "All #{matrix.size} CLI/worker pairs agree with reference checksum #{checksum}."

# Detailed counters run separately and are never enabled in timed processes.
profiles = {}
bytes = File.binread(wasm)
variants.each do |variant, disabled|
  next if variant == "phase1"
  %w[inline_mix call_mix].each do |export|
    vm = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false,
      engine: :efflorescence, disabled_optimizations: disabled, mir_profile: true).runtime
    abort "Profile checksum mismatch" unless vm.call_unboxed(export, [rounds, seed]) == checksum
    inspection = Wardite::Efflorescence::Inspection.new
    profiles["#{variant}/#{export}"] = {semantic: inspection.statistics(vm.semantic_ir),
      optimized: inspection.statistics(vm.optimized_ir), dispatches: vm.metrics.dispatches,
      copies: vm.metrics.copies, reads: vm.metrics.register_reads, writes: vm.metrics.register_writes,
      frames: vm.metrics.frames_created, opcode_counts: vm.metrics.opcode_counts}
  end
end

results = []
matrix.each do |name, variant, disabled, export, cli, worker|
  samples = []
  (warmups + runs).times do |iteration|
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    checked_cli(cli, checksum)
    e2e = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    phases = checked_worker(worker, checksum)
    samples << [e2e, *phases] if iteration >= warmups
  end
  means = (0...4).map { |i| samples.sum { |sample| sample[i] } * 1000 / runs }
  allocations = name == "Spinel" || variant == "phase1" ? nil : samples.sum { |sample| sample[4] } / runs.to_f
  results << {runtime: name, variant: variant, disabled: disabled, export: export,
    e2e_ms: means[0], load_ms: means[1], translate_ms: means[2], execute_ms: means[3],
    allocations: allocations, samples_seconds: samples}
  puts "%s/%s/%s: e2e=%.2f ms load=%.3f ms MIR=%.3f ms execute=%.2f ms allocations=%s" %
    [name, variant, export, *means, allocations || "n/a"]
end
document = {rounds: rounds, seed: seed, checksum: checksum, runs: runs, warmups: warmups,
  ruby: RUBY_DESCRIPTION, spinel: spinel_version.strip, spinel_flags: flags,
  results: results, profiles: profiles}
File.write("build/benchmark/optimizations.json", JSON.pretty_generate(document))
puts "Saved build/benchmark/optimizations.json"
