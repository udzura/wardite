# frozen_string_literal: true
# rbs_inline: enabled

require "wardite"

class M5ControlProbe
  # @rbs vm: Wardite::Efflorescence::VM
  # @rbs reuse_frames: bool
  # @rbs profile: bool
  # @rbs return: void
  def self.verify(vm, reuse_frames, profile)
    bits = Wardite::FloatBits
    result = vm.call_unboxed("reset", [])
    raise "float local reset" unless result.is_a?(Float) && bits.from_float(:f64, result) == 0
    expected_frames = reuse_frames ? 2 : 3
    raise "wrong frame count" if profile && vm.metrics.frames_created != expected_frames

    rounded = vm.call("choose", [Wardite::F32(1.0 + 2.0**-24), 1])
    raise "float argument rounding" unless rounded.is_a?(Wardite::F32) && rounded.value == 1.0
    negative_zero = vm.call_unboxed("identity", [-0.0])
    raise "float result sign" unless negative_zero.is_a?(Float) &&
      bits.from_float(:f64, negative_zero) == -9223372036854775807 - 1

    value = vm.call("constants", [])
    raise "boxed NaN" unless value.is_a?(Wardite::F32) && value.value.nan?
    raise "typed constants missing" unless vm.dump_mir.include?("f32 0xff800123")
    function = vm.semantic_ir.function_at(4)
    raise "typed constant deduplication" unless function.constant_registers.size == 6
    raise "void result" unless vm.call_unboxed("void", [0.0]).nil?

    raw64 = -4503599627370205
    identity = vm.call("identity", [Wardite::F64.from_bits(raw64)])
    raise "boxed f64 payload" unless identity.is_a?(Wardite::F64) && identity.raw_bits == raw64
    raise "recursive f64 payload" unless vm.call_unboxed("raw64", [1]) == raw64
    raise "f64 select payload" unless vm.call_unboxed("raw64", [0]) == 0x7ff0000000000124
    raise "mixed parallel copy payload" unless vm.call_unboxed("parallel", []) == (raw64 ^ 0xff800456)

    invalid = [1, Wardite::F64(1.0)] #: Array[Object]
    invalid.each do |argument|
      begin
        vm.call("choose", [argument, 1])
        raise "wrong argument accepted"
      rescue Wardite::ArgumentError
        # Expected
      end
    end
  end
end

[[], [:all], [:frames]].each do |disabled|
  [false, true].each do |profile|
    vm = File.open(ARGV.fetch(0), "rb") do |file|
      Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false, engine: :efflorescence,
        disabled_optimizations: disabled, mir_profile: profile).runtime
    end
    raise "wrong runtime" unless vm.is_a?(Wardite::Efflorescence::VM)

    M5ControlProbe.verify(vm, disabled.empty?, profile)
  end
end
puts "M5 float control passed"
