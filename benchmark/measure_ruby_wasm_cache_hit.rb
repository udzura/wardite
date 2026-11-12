# frozen_string_literal: true

# Usage: ruby benchmark/measure_ruby_wasm_cache_hit.rb RUBY_WASM BASELINE BASELINE_BIN CURRENT_BIN
require "digest"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

wasm, baseline, baseline_bin, current_bin = ARGV.map { |path| File.expand_path(path) }
abort "Usage: ruby #{$PROGRAM_NAME} RUBY_WASM BASELINE BASELINE_BIN CURRENT_BIN" unless ARGV.size == 4
current = File.expand_path("..", __dir__)
runs = Integer(ENV.fetch("RUNS", "7"))
warmups = Integer(ENV.fetch("WARMUPS", "2"))
abort "Invalid run or warmup count" unless runs >= 3 && warmups >= 0

guest = ["--disable-gems", "-e", "puts RUBY_DESCRIPTION"]
expected, status = Open3.capture2("wasmtime", "run", wasm, *guest)
abort "Wasmtime did not run Ruby 4.0.9" unless status.success? && expected.start_with?("ruby 4.0.9 ")

commands = [
  ["Spinel", "before", [baseline_bin]],
  ["Spinel", "after", [current_bin]],
]
{ "CRuby" => "--disable-yjit", "CRuby YJIT" => "--yjit" }.each do |runtime, option|
  { "before" => baseline, "after" => current }.each do |version, root|
    commands << [runtime, version, [RbConfig.ruby, option, "-I#{root}/lib", "#{root}/exe/wardite"]]
  end
end

samples = Dir.mktmpdir("wardite-cache-hit") do |cache|
  args = ["--new-engine", "--mir-cache", cache, "--", wasm, *guest]
  run = lambda do |command, cache_status|
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stdout, stderr, status = Open3.capture3({ "WARDITE_TRACE" => "1" }, *command, *args)
    total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    load = stderr[/^load_from_buffer: (\S+)$/, 1]
    unless status.success? && stdout == expected && stderr.include?("MIR2 cache #{cache_status}:") && load
      abort "#{command.inspect}\n#{stdout}#{stderr}"
    end
    load = Float(load)
    { process_seconds: total, load_seconds: load, guest_seconds: total - load }
  end

  # MIR2 keys include the runtime, so prime both native and CRuby entries.
  commands.select { |runtime, version, _| version == "before" && runtime != "CRuby YJIT" }.each do |_, _, command|
    run.call(command, "miss")
  end
  (warmups + runs).times.flat_map do |iteration|
    order = iteration.even? ? commands : commands.reverse
    order.filter_map do |runtime, version, command|
      result = run.call(command, "hit")
      result.merge(runtime: runtime, version: version, run: iteration - warmups + 1) if iteration >= warmups
    end
  end
end

puts JSON.pretty_generate(wasm_sha256: Digest::SHA256.file(wasm).hexdigest, guest: expected.strip,
  guest_arguments: guest, host_ruby: RUBY_DESCRIPTION, warmups: warmups, runs: runs, samples: samples)
