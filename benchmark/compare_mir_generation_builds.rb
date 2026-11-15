# frozen_string_literal: true

# Usage: ruby benchmark/compare_mir_generation_builds.rb BEFORE=DIR AFTER=DIR ... -- WASM...
# Build each directory with prepare_mir_generation_profile.rb and the same Spinel -O2.
require "digest"
require "json"
require "open3"
require "rbconfig"

separator = ARGV.index("--") || abort("Separate builds from fixtures with --")
builds = ARGV.take(separator).to_h do |argument|
  name, directory = argument.split("=", 2)
  abort "Expected NAME=DIR: #{argument}" unless directory && !name.empty?
  [name, File.expand_path(directory)]
end
fixtures = ARGV.drop(separator + 1)
abort "Supply at least two builds and one fixture" unless builds.size >= 2 && !fixtures.empty?
runs = Integer(ENV.fetch("RUNS", "5"))
warmups = Integer(ENV.fetch("WARMUPS", "1"))
abort "Invalid sample counts" unless runs > 0 && warmups >= 0
runtime = ENV.fetch("RUNTIME", "spinel")
abort "Unknown runtime: #{runtime}" unless %w[cruby spinel].include?(runtime)
timer = ENV["RSS"] == "1" ? ["/usr/bin/time", "-l"] : []
stats_columns = %w[functions instructions optimized_instructions registers max_registers eligible_functions eligible_instructions]

report = fixtures.to_h do |fixture|
  checksum = Digest::SHA256.file(fixture).hexdigest
  expected_stats = nil
  samples = []
  (warmups + runs).times do |iteration|
    # Reverse each pair of runs and rotate positions when comparing several stages.
    order = builds.to_a
    order.rotate!(iteration / 2) if order.size > 2
    order.reverse! if iteration.odd?
    order.each do |name, directory|
      command = if runtime == "spinel"
        ["#{directory}/worker"]
      else
        [RbConfig.ruby, "-I#{directory}/lib", "#{directory}/mir_generation_worker.rb"]
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout, stderr, status = Open3.capture3(*timer, *command, fixture, "default")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      abort "#{command.inspect} failed\n#{stdout}\n#{stderr}" unless status.success?
      rows = stdout.lines.map { |line| line.strip.split(",") }
      stats = rows.select { |column, _, _| stats_columns.include?(column) }.to_h { |column, value| [column, Integer(value)] }
      expected_stats ||= stats
      abort "IR counts differ for #{fixture} in #{name}" unless stats == expected_stats
      phase_rows = rows.reject { |column, _, _| stats_columns.include?(column) }
      seconds = phase_rows.to_h { |column, value, _| [column, Float(value)] }
      calls = phase_rows.to_h { |column, _, count| [column, Integer(count)] }
      rss = stderr[/^\s*(\d+)\s+maximum resident set size$/, 1]
      run = iteration - warmups + 1
      warn "#{File.basename(fixture)} #{name} #{run}: #{seconds.fetch('total').round(5)} s"
      if iteration >= warmups
        samples << {build: name, run: run, process_seconds: elapsed,
                    phases_seconds: seconds, calls: calls, peak_rss_bytes: rss && Integer(rss)}
      end
    end
  end
  [fixture, {sha256: checksum, bytes: File.size(fixture), ir_counts: expected_stats, samples: samples}]
end

puts JSON.generate(runtime: runtime, runs: runs, warmups: warmups,
                   timing: "cache disabled; total is load_from_buffer; process includes startup and statistics",
                   fixtures: report)
