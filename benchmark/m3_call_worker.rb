# frozen_string_literal: true
# rbs_inline: enabled

require "wardite"

class IncrementHost
  include Wardite::WasmModule

  def increment(_store, arguments)
    value = arguments[0]
    raise "expected boxed i32" unless value.is_a?(Wardite::I32)
    value.value + 1
  end
end

# Keep the native receiver concrete at the public API boundary.
class M3CallProbe
  # @rbs vm: Wardite::Efflorescence::VM
  # @rbs export: String
  # @rbs rounds: Integer
  # @rbs return: Integer?
  def self.run(vm, export, rounds)
    vm.call_unboxed(export, [rounds, 123])
  end
end

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
instance = File.open(ARGV.fetch(0), "rb") do |file|
  Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false, engine: :efflorescence,
    disabled_optimizations: [:inline], import_object: {env: IncrementHost.new})
end
loaded = Process.clock_gettime(Process::CLOCK_MONOTONIC)
vm = instance.runtime
raise "wrong engine" unless vm.is_a?(Wardite::Efflorescence::VM)
checksum = M3CallProbe.run(vm, ARGV.fetch(1), ARGV.fetch(2).to_i)
finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
raise "missing checksum" unless checksum
puts "#{loaded - started},#{finished - loaded},#{checksum}"
