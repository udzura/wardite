# frozen_string_literal: true

# Usage: ruby benchmark/measure_mir_generation.rb BUILD_DIR WASM...
# BUILD_DIR contains the generated worker.rb and optionally a Spinel `worker`.
require "json"
require "open3"
require "digest"
require "rbconfig"

directory = File.expand_path(ARGV.shift || abort("Missing build directory"))
abort "Missing Wasm fixtures" if ARGV.empty?
runs = Integer(ENV.fetch("RUNS", "5"))
warmups = Integer(ENV.fetch("WARMUPS", "1"))
abort "Invalid sample counts" unless runs > 0 && warmups >= 0
commands = {
  "cruby" => [RbConfig.ruby, "-I#{directory}/lib", "#{directory}/mir_generation_worker.rb"],
  "spinel" => ["#{directory}/worker"]
}
commands.select! { |runtime, _| ENV.fetch("RUNTIMES", "cruby,spinel").split(",").include?(runtime) }
variants = ENV.fetch("VARIANTS", "default").split(",")
abort "Unknown variant" unless (variants - %w[default no-inline]).empty?
fixtures = ARGV.map { |path| File.expand_path(path) }
samples = []
fixtures.each do |fixture|
  expected_stats = {}
  (warmups + runs).times do |iteration|
    commands.to_a.product(variants).rotate(iteration).each do |(runtime, command), variant|
      timer = ENV["RSS"] == "1" ? ["/usr/bin/time", "-l"] : []
      stdout, stderr, status = Open3.capture3(*timer, *command, fixture, variant)
      abort "#{command.inspect}: #{stdout}\n#{stderr}" unless status.success?
      rows = stdout.lines.map { |line| line.strip.split(",") }
      phases = rows.to_h { |name, seconds, count| [name, {value: Float(seconds), calls: Integer(count)}] }
      abort "Missing total" unless phases.key?("total")
      stats = phases.select { |name, _| %w[functions instructions optimized_instructions registers max_registers eligible_functions eligible_instructions].include?(name) }
      expected_stats[variant] ||= stats
      abort "Inconsistent IR counts for #{fixture}" unless stats == expected_stats[variant]
      rss = stderr[/^\s*(\d+)\s+maximum resident set size$/, 1]
      sample = {fixture: fixture, runtime: runtime, variant: variant, run: iteration - warmups + 1,
                phases: phases, peak_rss_bytes: rss && Integer(rss)}
      warn "#{File.basename(fixture)} #{runtime} #{variant} #{sample[:run]}: #{phases['total'][:value].round(4)} s"
      samples << sample if iteration >= warmups
    end
  end
end
puts JSON.pretty_generate(
  revision: IO.popen(["git", "rev-parse", "HEAD"], &:read).strip,
  ruby: RUBY_DESCRIPTION, directory: directory, commands: commands,
  runs: runs, warmups: warmups, variants: variants,
  timing: "load_from_buffer only; no cache or export execution; nested detail timers are inclusive",
  fixtures: fixtures.to_h { |path| [path, {bytes: File.size(path), sha256: Digest::SHA256.file(path).hexdigest}] },
  samples: samples
)
