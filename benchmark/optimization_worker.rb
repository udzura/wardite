# frozen_string_literal: true
# rbs_inline: enabled

require "wardite"

wasm = ARGV.fetch(0)
export = ARGV.fetch(1)
rounds = ARGV.fetch(2).to_i
seed = ARGV.fetch(3).to_i
disabled = ARGV.fetch(4, "").split(",").map { |name| name.to_sym }
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
instance = File.open(wasm, "rb") do |file|
  Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false)
end
loaded = Process.clock_gettime(Process::CLOCK_MONOTONIC)
vm = Wardite::Efflorescence::VM.new(instance, disabled_optimizations: disabled)
translated = Process.clock_gettime(Process::CLOCK_MONOTONIC)
before = RUBY_ENGINE == "spinel" ? 0 : GC.stat(:total_allocated_objects)
execution_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
result = vm.call(export, [rounds, seed]) || raise("missing checksum")
finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
after = RUBY_ENGINE == "spinel" ? 0 : GC.stat(:total_allocated_objects)
puts "#{loaded - started},#{translated - loaded},#{finished - execution_started},#{result.value},#{after - before}"
