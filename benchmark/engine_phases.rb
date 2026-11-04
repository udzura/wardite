# frozen_string_literal: true
# rbs_inline: enabled

# Compiled unchanged by Spinel. Print seconds for loading, MIR translation and
# execution, followed by the unsigned checksum. The fixture has no start section.
require "wardite"

wasm = ARGV.fetch(0)
engine = ARGV.fetch(1)
export = ARGV.fetch(2)
rounds = ARGV.fetch(3).to_i
seed = ARGV.fetch(4).to_i
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
instance = File.open(wasm, "rb") do |file|
  Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false)
end
loaded = Process.clock_gettime(Process::CLOCK_MONOTONIC)
if engine == "efflorescence"
  mir_vm = Wardite::Efflorescence::VM.new(instance)
  translated = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = mir_vm.call(export, [rounds, seed]) || raise("missing checksum")
else
  # Construct each engine explicitly after shared loading, keeping receiver
  # types concrete in Spinel. The fixture has no start function to invoke twice.
  stack_vm = Wardite::Runtime.new(instance)
  translated = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = stack_vm.call(export, [rounds, seed]) || raise("missing checksum")
end
finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
puts "#{loaded - started},#{translated - loaded},#{finished - translated},#{result.value}"
