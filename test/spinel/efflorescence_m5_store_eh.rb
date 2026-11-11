# frozen_string_literal: true
# rbs_inline: enabled

require "wardite"

class M5StoreProbe
  # @rbs vm: Wardite::Efflorescence::VM
  # @rbs reuse_frames: bool
  # @rbs profile: bool
  # @rbs return: void
  def self.verify(vm, reuse_frames, profile)
    nan32 = 0xff800123
    nan64 = -4503599627369386
    min = -9223372036854775807 - 1
    raise "global initializer32" unless vm.call_unboxed("global32", []) == nan32
    raise "global initializer64" unless vm.call_unboxed("global64", []) == nan64
    raise "global snapshot32" unless vm.call_unboxed("update32", [0x7f800124]) == nan32
    raise "global snapshot64" unless vm.call_unboxed("update64", [min]) == nan64
    raise "global update32" unless vm.call_unboxed("global32", []) == 0x7f800124
    raise "global update64" unless vm.call_unboxed("global64", []) == min

    value = vm.instance.store.globals.fetch(0).value
    raise "global wrapper" unless value.is_a?(Wardite::F32)
    value.value = -0.0
    raise "stale raw global value" unless vm.call_unboxed("global32", []) == 0x80000000

    large = vm.instance.store.globals.fetch(1).value
    raise "f64 global wrapper" unless large.is_a?(Wardite::F64)
    large.value = 1.25
    raise "stale raw f64 global value" unless vm.call_unboxed("global64", []) == 0x3ff4000000000000

    raise "float store result" unless vm.call_unboxed("write32", [65531, nan32]).nil?
    raise "float load32 payload" unless vm.call_unboxed("read32", [65531]) == nan32
    raise "float store result" unless vm.call_unboxed("write64", [0, nan64]).nil?
    raise "float load64 payload" unless vm.call_unboxed("read64", [0]) == nan64
    begin
      vm.call_unboxed("write32", [65532, 0])
      raise "partial store did not trap"
    rescue Wardite::EvalError => error
      raise error unless error.message == "out of bounds memory access"
    end
    raise "trapping store modified memory" unless vm.call_unboxed("read32", [65531]) == nan32
    begin
      vm.call_unboxed("read64", [-1])
      raise "overflowed effective address did not trap"
    rescue Wardite::EvalError => error
      raise error unless error.message == "out of bounds memory access"
    end

    raise "caught/rethrown payload" unless vm.call_unboxed("eh", []) == 1
    raise "repeated mixed catch" unless vm.call_unboxed("repeat_eh", []) == 1
    expected_frames = reuse_frames ? 3 : 5
    raise "mixed EH frame release" if profile && vm.metrics.frames_created != expected_frames
    begin
      vm.call_unboxed("raise", [])
      raise "expected uncaught exception"
    rescue Wardite::UncaughtWasmException => error
      payload = error.payload
      first_float = payload.fetch(1)
      second_float = payload.fetch(3)
      raise "public payload integers" unless payload.fetch(0) == 4294967295 && payload.fetch(2) == -7
      raise "public f32 payload" unless first_float.is_a?(Float) && first_float.nan?
      raise "public f64 payload" unless second_float.is_a?(Float) && Wardite::FloatBits.from_float(:f64, second_float) == min
      raise "lost raw exception bits" unless error.exception_value.payload_bits.fetch(1) == nan32
    end
    begin
      vm.call_unboxed("trap", [])
      raise "truncation trap was caught by Wasm"
    rescue Wardite::EvalError => error
      raise error unless error.message == "invalid conversion to integer"
    end
    raise "exception recovery" unless vm.call_unboxed("eh", []) == 1
  end
end

[[], [:all], [:frames]].each do |disabled|
  [false, true].each do |profile|
    vm = File.open(ARGV.fetch(0), "rb") do |file|
      Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false, engine: :efflorescence,
        disabled_optimizations: disabled, mir_profile: profile).runtime
    end
    raise "wrong runtime" unless vm.is_a?(Wardite::Efflorescence::VM)
    M5StoreProbe.verify(vm, disabled.empty?, profile)
  end
end
puts "M5 float Store and EH passed"
