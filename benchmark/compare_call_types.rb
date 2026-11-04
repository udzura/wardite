# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"

Dir.chdir(File.expand_path("..", __dir__))
$stdout.sync = true
ablation = ENV["INLINE_ABLATION"] == "1"
output = File.expand_path(ablation ? "build/benchmark/inlining" : "build/benchmark/call-types")
FileUtils.mkdir_p(output)
rounds = Integer(ARGV.fetch(0, "1000000"), 10)
seed = Integer(ARGV.fetch(1, "123"), 10)
runs = Integer(ENV.fetch("RUNS", "7"))
warmups = Integer(ENV.fetch("WARMUPS", "2"))
abort "invalid inputs" unless (0..0x7fffffff).cover?(rounds) && (0..0xffffffff).cover?(seed) && runs > 1 && warmups >= 0
exports = %w[empty_loop call_identity call_add_one inline_mix call_mix]
runtimes = ENV.fetch("RUNTIMES", "Spinel").split(",").uniq
abort "invalid RUNTIMES" if runtimes.empty? || !(runtimes - %w[Spinel CRuby YJIT]).empty?
if runtimes.include?("YJIT")
  out, status = Open3.capture2e(RbConfig.ruby, "--yjit", "-e", "abort 'YJIT unavailable' unless defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?")
  abort out unless status.success?
end
compiler = Shellwords.split(ENV.fetch("SPINEL", "spinel"))
flags = Shellwords.split(ENV.fetch("SPINELFLAGS", "-O2"))
version, status = Open3.capture2e(*compiler, "--version")
abort version unless status.success?
baseline = nil
unless ablation
  baseline, status = Open3.capture2e("git", "rev-parse", "--verify", "--end-of-options", "#{ENV.fetch("BASELINE_REF", "fa4b14e")}^{commit}")
  abort baseline unless status.success?
  baseline = baseline.strip
end

def run!(command, log)
  abort "Failed: #{command.inspect}; see #{log}" unless system(*command, out: log, err: [:child, :out])
end

def reference(name, rounds, seed)
  return seed if %w[empty_loop call_identity].include?(name)
  return (seed + rounds) % (2**32) if name == "call_add_one"
  x = seed
  rounds.times do
    x ^= x / 8192
    x = (x * 1664525 + 1013904223) % (2**32)
    x = (x ^ (x * 128)) % (2**32)
  end
  x
end

def worker_sample(command, expected)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  out, err, status = Open3.capture3(*command)
  e2e = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  fields = out.lines.first.to_s.strip.split(",")
  abort "Checksum mismatch: #{command.inspect}\n#{out}#{err}" unless status.success? && fields.size == 4 && Integer(fields[3]) == expected
  {worker_e2e: e2e, load: Float(fields[0]), translate: Float(fields[1]), execute: Float(fields[2]),
    metrics: out.lines[1]&.strip, mir: out.lines[2]&.strip}
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
  {mean: mean, sd: Math.sqrt(values.sum { |value| (value - mean)**2 } / (values.size - 1)), min: values.min, max: values.max}
end

wasm = "#{output}/i32_calls.wasm"
run!(["wasm-tools", "parse", "benchmark/i32_calls.wat", "-o", wasm], "#{output}/wat-build.log")
archive = "#{output}/baseline.tar"
run!(["git", "archive", "--output", archive, baseline, "lib", "exe", "benchmark/call_cost_worker.rb"], "#{output}/archive.log") unless ablation
snapshots = {}
(ablation ? ["current"] : %w[baseline current]).each do |variant|
  directory = "#{output}/#{variant}"
  FileUtils.mkdir_p(directory)
  %w[lib exe benchmark].each { |name| FileUtils.rm_rf("#{directory}/#{name}") }
  if variant == "baseline"
    run!(["tar", "-xf", archive, "-C", directory], "#{output}/extract.log")
  else
    FileUtils.cp_r(["lib", "exe"], directory)
    FileUtils.mkdir_p("#{directory}/benchmark")
    FileUtils.cp("benchmark/call_cost_worker.rb", "#{directory}/benchmark")
  end
  sources = Dir["#{directory}/{lib,exe,benchmark}/**/*"].select { |path| File.file?(path) }.sort.to_h do |path|
    [path.delete_prefix("#{directory}/"), Digest::SHA256.file(path).hexdigest]
  end
  fingerprint = Digest::SHA256.hexdigest(JSON.generate([compiler, version, flags, sources]))
  manifest_path = "#{directory}/build-manifest.json"
  manifest = File.exist?(manifest_path) ? JSON.parse(File.read(manifest_path)) : {}
  cached = manifest["fingerprint"] == fingerprint && %w[wardite worker].all? do |name|
    File.exist?("#{directory}/#{name}") && Digest::SHA256.file("#{directory}/#{name}").hexdigest == manifest.fetch("binaries", {})[name]
  end
  unless cached
    {"wardite" => "exe/wardite", "worker" => "benchmark/call_cost_worker.rb"}.each do |binary, entry|
      run!([*compiler, "-I#{directory}/lib", "--strict-require", *flags, "#{directory}/#{entry}", "-o", "#{directory}/#{binary}"], "#{directory}/#{binary}-build.log")
    end
  end
  binaries = %w[wardite worker].to_h { |name| [name, Digest::SHA256.file("#{directory}/#{name}").hexdigest] }
  File.write(manifest_path, JSON.pretty_generate({fingerprint: fingerprint, binaries: binaries}) + "\n")
  snapshots[variant] = {directory: directory, source_sha256: sources, binary_sha256: binaries}
  puts "#{cached ? "Reused verified build" : "Built"} #{variant}"
end

checksums = exports.to_h { |name| [name, reference(name, rounds, seed)] }
variants = ablation ? %w[inline_off inline_on] : %w[baseline current]
rows = runtimes.flat_map do |runtime|
  exports.flat_map do |name|
    variants.map do |variant|
      snapshot = snapshots.fetch(ablation ? "current" : variant)
      directory = snapshot[:directory]
      # Historical CALL-mechanism comparisons must keep calls in the MIR.
      # Older snapshots predate the switch, so pass it only when supported.
      features = File.read("#{directory}/lib/wardite/efflorescence/optimizer.rb")[/FEATURES = %i\[([^\]]+)\]/, 1].to_s.split
      disabled = variant == "inline_off" || (!ablation && features.include?("inline")) ? "inline" : ""
      ruby = [RbConfig.ruby, runtime == "YJIT" ? "--yjit" : "--disable-yjit", "-I#{directory}/lib"]
      worker = runtime == "Spinel" ? ["#{directory}/worker"] : [*ruby, "#{directory}/benchmark/call_cost_worker.rb"]
      worker += [wasm, name, rounds.to_s, seed.to_s]
      profile = worker_sample([*worker, disabled, "metrics"], checksums.fetch(name))
      cli = runtime == "Spinel" ? ["#{directory}/wardite"] : [*ruby, "#{directory}/exe/wardite"]
      cli += ["--mir-disable", "inline"] unless disabled.empty?
      cli += ["--new-engine", "--no-wasi", "--invoke", name, "--", wasm, rounds.to_s, seed.to_s]
      # Only the acceptance exports get separate CLI timings. All controls use
      # the same phase worker and public unboxed boundary as previous experiments.
      cli = nil unless %w[inline_mix call_mix].include?(name)
      {runtime: runtime, variant: variant, disabled: disabled, export: name, worker: worker, cli: cli,
        metrics: profile.fetch(:metrics), mir: profile.fetch(:mir), samples: []}
    end
  end
end
rows.each do |row|
  [[0, 0], [0, 123], [1, 0xffffffff], [10, 123], [1000, 0xffffffff]].each do |count, initial|
    command = row[:worker].dup
    command[-2] = count.to_s
    command[-1] = initial.to_s
    worker_sample([*command, row[:disabled]], reference(row[:export], count, initial))
  end
end
runtimes.product(exports).each do |runtime, name|
  before = rows.find { |row| row[:runtime] == runtime && row[:variant] == variants[0] && row[:export] == name }
  after = rows.find { |row| row[:runtime] == runtime && row[:variant] == variants[1] && row[:export] == name }
  if ablation && name.start_with?("call_")
    off = before[:metrics].split.to_h { |field| key, value = field.split("="); [key, Integer(value)] }
    on = after[:metrics].split.to_h { |field| key, value = field.split("="); [key, Integer(value)] }
    abort "Unexpected inlining counters" unless off.fetch("function_entries") == rounds + 1 &&
      on.fetch("function_entries") == 1 && on.fetch("frames_created") == 1 && on.fetch("dispatches") <= off.fetch("dispatches")
  else
    abort "MIR metrics differ" unless before[:metrics] == after[:metrics]
  end
end
puts "All boundary and measured checksums agree with the independent reference."

(warmups + runs).times do |iteration|
  ordered = rows.rotate(iteration * 3)
  ordered.reverse! if iteration.odd?
  ordered.each do |row|
    expected = checksums.fetch(row[:export])
    sample = worker_sample([*row[:worker], row[:disabled]], expected).reject { |key, _| [:metrics, :mir].include?(key) }
    sample[:cli_e2e] = cli_sample(row[:cli], expected) if row[:cli]
    row[:samples] << sample if iteration >= warmups
  end
  puts "Completed #{iteration < warmups ? "warmup" : "sample"} #{iteration < warmups ? iteration + 1 : iteration - warmups + 1}"
end
rows.each do |row|
  row[:statistics_ms] = row[:samples].first.keys.to_h do |phase|
    [phase, statistics(row[:samples].map { |sample| sample.fetch(phase) * 1000 })]
  end
  stat = row[:statistics_ms][:execute]
  puts "%s/%s/%s: %.3f ± %.3f ms" % [row[:runtime], row[:export], row[:variant], stat[:mean], stat[:sd]]
  row.delete(:worker)
  row.delete(:cli)
end
snapshots.each_value { |snapshot| snapshot.delete(:directory) }
report = {comparison: ablation ? "same binary, inline off/on" : "commits", baseline_commit: baseline,
  rounds: rounds, seed: seed, runs: runs, warmups: warmups,
  spinel: version.strip, spinel_flags: flags, ruby: RUBY_DESCRIPTION, checksums: checksums, snapshots: snapshots, results: rows}
File.write("#{output}/results.json", JSON.pretty_generate(report) + "\n")
puts "Saved #{output}/results.json"
