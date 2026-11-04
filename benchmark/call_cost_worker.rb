# frozen_string_literal: true
# rbs_inline: enabled

# Keep the same entry point for every native variant. Counters are collected in
# a separate process; they never run during a timing sample.
require "wardite"

wasm = ARGV.fetch(0)
export = ARGV.fetch(1)
rounds = ARGV.fetch(2).to_i
seed = ARGV.fetch(3).to_i
disabled = ARGV.fetch(4, "").split(",").map { |name| name.to_sym }
profile = ARGV.fetch(5, "time") == "metrics"
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
instance = File.open(wasm, "rb") do |file|
  Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false)
end
loaded = Process.clock_gettime(Process::CLOCK_MONOTONIC)
vm = Wardite::Efflorescence::VM.new(instance, disabled_optimizations: disabled, profile: profile)
translated = Process.clock_gettime(Process::CLOCK_MONOTONIC)
result = vm.call_unboxed(export, [rounds, seed]) || raise("missing checksum")
finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
puts "#{loaded - started},#{translated - loaded},#{finished - translated},#{result}"
puts vm.metrics.report if profile
