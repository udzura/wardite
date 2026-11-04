# frozen_string_literal: true

# Reconstruct the constant-label baseline from the current VM's Opcode comments
# so both variants contain exactly the same optimizations and return boundary.
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"

Dir.chdir(File.expand_path("..", __dir__))
$stdout.sync = true
root = Dir.pwd
rounds = Integer(ARGV.fetch(0, "100000"), 10)
seed = Integer(ARGV.fetch(1, "123"), 10)
runs = Integer(ENV.fetch("RUNS", "5"))
warmups = Integer(ENV.fetch("WARMUPS", "2"))
abort "invalid inputs" unless (0..0x7fffffff).cover?(rounds) && (0..0xffffffff).cover?(seed) && runs > 0 && warmups >= 0
compiler = Shellwords.split(ENV.fetch("SPINEL", "spinel"))
flags = Shellwords.split(ENV.fetch("SPINELFLAGS", "-O2"))
version, status = Open3.capture2e(*compiler, "--version")
abort version unless status.success?
FileUtils.mkdir_p("build/benchmark")
wasm = File.expand_path("build/benchmark/i32_mix.wasm")
abort "WAT compilation failed" unless system("wasm-tools", "parse", "benchmark/i32_mix.wat", "-o", wasm)
abort "CLI build failed" unless system("make", "spinel", out: "build/benchmark/dispatch-build.log", err: [:child, :out])

def compile(compiler, flags, source, library, destination, log)
  abort "Build failed; see #{log}" unless system(*compiler, "--strict-require", "-I#{library}", *flags,
    source, "-o", destination, out: log, err: [:child, :out])
end

def verify(command, expected, worker: false)
  out, err, status = Open3.capture3(*command)
  values = out.strip.split(",")
  signed = expected >= 0x80000000 ? expected - 0x100000000 : expected
  valid = if worker
    values.size == 5 && Integer(values[3]) == expected
  else
    out.empty? && err == "return value: I32(#{signed})\n"
  end
  abort "Checksum mismatch: #{command.inspect}\n#{out}#{err}" unless status.success? && valid
  worker ? values.first(3).map { |value| Float(value) } : []
end

checksum = seed
rounds.times do
  checksum ^= checksum / 8192
  checksum = (checksum * 1664525 + 1013904223) % (2**32)
  checksum = (checksum ^ (checksum * 128)) % (2**32)
end
compile(compiler, flags, "benchmark/optimization_worker.rb", "lib", "build/benchmark/optimization_worker",
  "build/benchmark/dispatch-worker-build.log")

results = []
Dir.mktmpdir("dispatch-constants-", "build/benchmark") do |temporary|
  baseline = File.expand_path(temporary)
  FileUtils.cp_r(["lib", "exe"], baseline)
  FileUtils.mkdir_p("#{baseline}/benchmark")
  FileUtils.cp("benchmark/optimization_worker.rb", "#{baseline}/benchmark/optimization_worker.rb")
  vm_file = "#{baseline}/lib/wardite/efflorescence/vm.rb"
  source = File.read(vm_file).gsub(/^([ ]*)when \d+ # (Opcode::[A-Z_0-9]+)$/) { "#{$1}when #{$2}" }
  # Count the original labels independently to guard against a stale benchmark.
  labels = File.read(vm_file).scan(/^\s*when \d+ # Opcode::[A-Z_0-9]+$/).size
  abort "Expected both 23-opcode dispatches, found #{labels} labels" unless labels == 46
  File.write(vm_file, source)
  compile(compiler, flags, "#{baseline}/exe/wardite", "#{baseline}/lib", "#{baseline}/wardite",
    "build/benchmark/dispatch-constant-build.log")
  compile(compiler, flags, "#{baseline}/benchmark/optimization_worker.rb", "#{baseline}/lib", "#{baseline}/worker",
    "build/benchmark/dispatch-constant-worker-build.log")

  runtimes = {"CRuby" => [RbConfig.ruby, "--disable-yjit"], "Spinel" => []}
  _out, yjit = Open3.capture2e(RbConfig.ruby, "--yjit", "-e", "exit(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? 0 : 1)")
  runtimes["YJIT"] = [RbConfig.ruby, "--yjit"] if yjit.success?
  if ENV["RUNTIMES"]
    requested = ENV.fetch("RUNTIMES").split(",")
    abort "Unknown runtime" if requested.empty? || !(requested - runtimes.keys).empty?
    runtimes.select! { |name, _| requested.include?(name) }
  end
  matrix = []
  runtimes.each do |name, runner|
    %w[inline_mix call_mix].each do |export|
      %w[constant literal].each do |style|
        directory = style == "constant" ? baseline : root
        if name == "Spinel"
          cli = [style == "constant" ? "#{baseline}/wardite" : "#{root}/build/wardite"]
          worker = [style == "constant" ? "#{baseline}/worker" : "#{root}/build/benchmark/optimization_worker"]
        else
          cli = runner + ["-I#{directory}/lib", "#{directory}/exe/wardite"]
          worker = runner + ["-I#{directory}/lib", "#{directory}/benchmark/optimization_worker.rb"]
        end
        cli += ["--new-engine", "--no-wasi", "--invoke", export, "--", wasm, rounds.to_s, seed.to_s]
        worker += [wasm, export, rounds.to_s, seed.to_s, ""]
        verify(cli, checksum)
        verify(worker, checksum, worker: true)
        matrix << {runtime: name, export: export, style: style, cli: cli, worker: worker, samples: []}
      end
    end
  end
  puts "All #{matrix.size} CLI/worker pairs match checksum #{checksum}."
  matrix.each_slice(2) do |pair|
    (warmups + runs).times do |iteration|
      # Alternate the order of paired samples to reduce ordering bias.
      (iteration.even? ? pair : pair.reverse).each do |row|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        verify(row[:cli], checksum)
        e2e = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        phases = verify(row[:worker], checksum, worker: true)
        row[:samples] << [e2e, *phases] if iteration >= warmups
      end
    end
    pair.each do |row|
      means = (0...4).map { |i| row[:samples].sum { |sample| sample[i] } * 1000 / runs }
      results << {runtime: row[:runtime], export: row[:export], style: row[:style],
        e2e_ms: means[0], load_ms: means[1], translate_ms: means[2], execute_ms: means[3], samples_seconds: row[:samples]}
      puts "%s/%s/%s: e2e=%.2f ms execute=%.2f ms" % [row[:runtime], row[:export], row[:style], means[0], means[3]]
    end
  end
end
File.write("build/benchmark/dispatch.json", JSON.pretty_generate({rounds: rounds, seed: seed, checksum: checksum,
  runs: runs, warmups: warmups, ruby: RUBY_DESCRIPTION, spinel: version.strip, spinel_flags: flags, results: results}))
puts "Saved build/benchmark/dispatch.json"
