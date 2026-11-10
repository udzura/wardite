# frozen_string_literal: true
# rbs_inline: enabled

# Run with a compiled benchmark/float_m5.wat.
require "wardite"

class FloatBoundaryBenchmark
  # @rbs vm: Wardite::Efflorescence::VM
  # @rbs rounds: Integer
  # @rbs boxed: bool
  # @rbs return: Float
  def self.measure(vm, rounds, boxed)
    arguments = [1.25]
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    index = 0
    if boxed
      while index < rounds
        result = vm.call("float_identity", arguments)
        raise "boxed result" unless result.is_a?(Wardite::F32) && result.value == 1.25
        index += 1
      end
    else
      while index < rounds
        raise "unboxed result" unless vm.call_unboxed("float_identity", arguments) == 1.25
        index += 1
      end
    end
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
  end
end

vm = Wardite.new(path: ARGV.fetch(0), enable_wasi: false, engine: :efflorescence).runtime
raise "wrong engine" unless vm.is_a?(Wardite::Efflorescence::VM)
rounds = ARGV.fetch(1, "30000").to_i
5.times do |trial|
  boxed_first = trial.odd?
  first = FloatBoundaryBenchmark.measure(vm, rounds, boxed_first)
  second = FloatBoundaryBenchmark.measure(vm, rounds, !boxed_first)
  unboxed, boxed = boxed_first ? [second, first] : [first, second]
  puts "#{unboxed},#{boxed}"
end
