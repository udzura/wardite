# frozen_string_literal: true
# rbs_inline: enabled

require "wardite"
require_relative "efflorescence_m2_probe"

class M4Probe
  # @rbs vm: Wardite::Efflorescence::VM
  # @rbs arguments: Array[Object]
  # @rbs return: (Wardite::I32 | Wardite::I64)?
  def self.boxed(vm, arguments)
    vm.call("identity", arguments)
  end
end

runtime = File.open(ARGV.fetch(0), "rb") do |file|
  Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false, engine: :efflorescence).runtime
end
raise "wrong runtime" unless runtime.is_a?(Wardite::Efflorescence::VM)
min = -9223372036854775807 - 1
raise "recursive result" unless M2Probe.call(runtime, "recursive", [4, min]) == min
raise "local reset" unless M2Probe.call(runtime, "reset", [-1]) == 0
raise "select snapshot" unless M2Probe.call(runtime, "select", [min, 1]) == min
raise "mixed branch" unless M2Probe.call(runtime, "branch", [0]) == min
raise "boxed argument" unless M2Probe.call(runtime, "identity", [Wardite::I64(-1)]) == -1
boxed = M4Probe.boxed(runtime, [-1])
raise "boxed result" unless boxed.is_a?(Wardite::I64) && boxed.value_s == -1
puts "M4 control passed"
