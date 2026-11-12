# frozen_string_literal: true

# Usage: ruby benchmark/measure_mir_cache_verify.rb RUBY_WASM BASELINE_BIN CURRENT_BIN
require "digest"
require "json"
require "open3"
require "tmpdir"

abort "Usage: ruby #{$PROGRAM_NAME} RUBY_WASM BASELINE_BIN CURRENT_BIN" unless ARGV.size == 3
wasm, baseline, current = ARGV.map { |path| File.expand_path(path) }
runs = Integer(ENV.fetch("RUNS", "9"))
warmups = Integer(ENV.fetch("WARMUPS", "2"))
abort "Invalid run or warmup count" unless runs >= 3 && warmups >= 0

guest = ["--disable-gems", "-e", "puts RUBY_VERSION"]
expected, status = Open3.capture2("wasmtime", "run", wasm, *guest)
abort "Wasmtime did not run Ruby 4.0.9" unless status.success? && expected == "4.0.9\n"

def invoke(command, expected, *traces)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  stdout, stderr, status = Open3.capture3({"WARDITE_TRACE" => "1"}, *command, unsetenv_others: true)
  total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  load_time = stderr[/^load_from_buffer: (\S+)$/, 1]
  unless status.success? && stdout == expected && load_time && traces.all? { |trace| stderr.include?(trace) }
    abort "#{command.inspect}\n#{stdout}#{stderr}"
  end
  {load_seconds: Float(load_time), process_seconds: total}
end

samples = Dir.mktmpdir("wardite-mir-cache-verify") do |directory|
  baseline_cache = [baseline, "--new-engine", "--mir-cache", File.join(directory, "before")]
  current_cache = [current, "--new-engine", "--mir-cache", File.join(directory, "after")]
  inputs = ["--", wasm, *guest]
  snapshot = ->(version) { ["--snapshot", File.join(directory, "#{version}-snapshot")] }
  invoke([*baseline_cache, *snapshot.call("before"), *inputs], expected, "MIR2 cache miss:", "snapshot saved:")
  invoke([*current_cache, *snapshot.call("after"), *inputs], expected, "MIR2 cache miss:", "snapshot saved:")

  [false, true].flat_map do |with_snapshot|
    commands = {
      "before" => baseline_cache,
      "sha256" => [*current_cache, "--mir-cache-verify", "sha256"],
      "checksum" => [*current_cache, "--mir-cache-verify", "checksum"],
    }
    traces = ["MIR2 cache hit:"]
    traces << "snapshot restored:" if with_snapshot
    (warmups + runs).times.flat_map do |iteration|
      commands.keys.rotate(iteration).filter_map do |mode|
        command = commands.fetch(mode)
        command = [*command, *snapshot.call(mode == "before" ? "before" : "after")] if with_snapshot
        sample = invoke([*command, *inputs], expected, *traces)
        sample.merge(mode: mode, snapshot: with_snapshot, run: iteration - warmups + 1) if iteration >= warmups
      end
    end
  end
end

puts JSON.pretty_generate(wasm_sha256: Digest::SHA256.file(wasm).hexdigest, guest_arguments: guest,
  runs: runs, warmups: warmups, samples: samples)
