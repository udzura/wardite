# frozen_string_literal: true

# Usage: ruby benchmark/measure_mir_cache_restore.rb WASM BEFORE_BIN DIRECT_BIN [LAZY_BIN]
require "digest"
require "json"
require "open3"
require "tmpdir"

abort "Usage: ruby #{$PROGRAM_NAME} WASM BEFORE_BIN DIRECT_BIN [LAZY_BIN]" unless (3..4).cover?(ARGV.size)
wasm, *binaries = ARGV.map { |path| File.expand_path(path) }
runs = Integer(ENV.fetch("RUNS", "6"))
warmups = Integer(ENV.fetch("WARMUPS", "1"))
abort "Invalid run or warmup count" unless runs >= 3 && warmups >= 0
snapshot = ENV["SNAPSHOT"] == "1"

guest = ["--disable-gems", "-e", "puts RUBY_VERSION"]
expected, status = Open3.capture2("wasmtime", "run", wasm, *guest)
abort "Wasmtime did not run Ruby 4.0.9" unless status.success? && expected == "4.0.9\n"

macos = RUBY_PLATFORM.include?("darwin")
timer = macos ? ["/usr/bin/time", "-l"] : ["/usr/bin/time", "-f", "%M maximum RSS KiB"]
rss_pattern = macos ? /^\s*(\d+)\s+maximum resident set size$/ : /^(\d+) maximum RSS KiB$/
invoke = lambda do |command, *traces|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  stdout, stderr, status = Open3.capture3({"WARDITE_TRACE" => "1"}, *timer, *command, unsetenv_others: true)
  total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  load = stderr[/^load_from_buffer: (\S+)$/, 1]
  rss = stderr[rss_pattern, 1]
  unless status.success? && stdout == expected && load && rss && traces.all? { |trace| stderr.include?(trace) }
    abort "#{command.inspect}\n#{stdout}#{stderr}"
  end
  {load_seconds: Float(load), process_seconds: total, after_load_seconds: total - Float(load),
    peak_rss_bytes: Integer(rss) * (macos ? 1 : 1024)}
end

samples = Dir.mktmpdir("wardite-mir-cache-restore") do |directory|
  commands = %w[before direct lazy].zip(binaries).filter_map do |version, binary|
    next unless binary
    command = [binary, "--new-engine", "--mir-cache", File.join(directory, version)]
    command += ["--snapshot", File.join(directory, "#{version}-snapshot")] if snapshot
    [version, [*command, "--", wasm, *guest]]
  end
  miss = ["MIR2 cache miss:"]
  hit = ["MIR2 cache hit:"]
  if snapshot
    miss << "snapshot saved:"
    hit << "snapshot restored:"
  end
  commands.each { |_, command| invoke.call(command, *miss) }
  (warmups + runs).times.flat_map do |iteration|
    commands.rotate(iteration).filter_map do |version, command|
      sample = invoke.call(command, *hit)
      sample.merge(version: version, run: iteration - warmups + 1) if iteration >= warmups
    end
  end
end

puts JSON.pretty_generate(wasm_sha256: Digest::SHA256.file(wasm).hexdigest, guest_arguments: guest,
  runs: runs, warmups: warmups, snapshot: snapshot, samples: samples)
