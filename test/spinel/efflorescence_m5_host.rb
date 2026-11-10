# frozen_string_literal: true
# rbs_inline: enabled

require "wardite"

class M5Host
  include Wardite::WasmModule

  attr_reader :calls #: Integer

  def initialize
    @vm = nil #: Wardite::Efflorescence::VM?
    @calls = 0
  end

  # @rbs vm: Wardite::Efflorescence::VM
  # @rbs return: void
  def attach(vm)
    @vm = vm
  end

  # @rbs args: Array[Wardite::wasmValue]
  # @rbs return: Wardite::wasmFuncReturn
  def mix(_store, args)
    @calls += 1
    mode, small, integer, large = args
    unless mode.is_a?(Wardite::I32) && small.is_a?(Wardite::F32) &&
        integer.is_a?(Wardite::I64) && large.is_a?(Wardite::F64)
      raise "incorrect host argument types"
    end
    raise "incorrect host argument bits" unless small.raw_bits == 0xff800123 &&
      integer.value_s == -1 && large.raw_bits == -9223372036854775807 - 1
    case mode.value
    when 0 then 1.0 + 2.0**-24
    when 1
      vm = @vm || raise("missing host runtime")
      vm.call("echo32", [small])
    when 2
      vm = @vm || raise("missing host runtime")
      begin
        vm.call_unboxed("fail", [])
        raise "missing nested trap"
      rescue Wardite::Unreachable
        Wardite::F32(-0.0)
      end
    when 3 then Wardite::F64(1.0)
    else 1
    end
  end

  # @rbs args: Array[Wardite::wasmValue]
  # @rbs return: Wardite::wasmFuncReturn
  def echo64(_store, args)
    value = args.fetch(0)
    raise "incorrect f64 host argument" unless value.is_a?(Wardite::F64)
    value
  end
end

class M5HostProbe
  # @rbs vm: Wardite::Efflorescence::VM
  # @rbs host: M5Host
  # @rbs profile: bool
  # @rbs return: void
  def self.verify(vm, host, profile)
    nan = 0xff800123
    raise "unrounded float host return" unless vm.call_unboxed("direct", [0]) == 0x3f800000
    raise "defined indirect float result" unless vm.call_unboxed("indirect", [1, 0]) == nan
    raise "reentrant indirect float result" unless vm.call_unboxed("indirect", [0, 1]) == nan
    if profile
      metrics = vm.metrics
      raise "reentry overwrote outer metrics" unless metrics.host_calls == 1 && metrics.indirect_calls == 1 &&
        metrics.function_entries == 2 && metrics.frames_created == 1
    end
    raise "recovery from nested trap" unless vm.call_unboxed("direct", [2]) == 0x80000000
    result = vm.call_unboxed("mix", [0, Wardite::F32.from_bits(nan), -1, -0.0])
    raise "reexported float result" unless result.is_a?(Float) && result == 1.0
    boxed = vm.call("echo64", [Wardite::F64.from_bits(-4503599627370205)])
    raise "reexported f64 bits" unless boxed.is_a?(Wardite::F64) && boxed.raw_bits == -4503599627370205

    before = host.calls
    begin
      vm.call_unboxed("indirect", [2, 0])
      raise "missing indirect signature trap"
    rescue Wardite::EvalError => error
      raise error unless error.message.include?("function type mismatch")
    end
    raise "host called on type mismatch" unless host.calls == before
    [3, 4].each do |mode|
      begin
        vm.call_unboxed("direct", [mode])
        raise "wrong host result accepted"
      rescue Wardite::EvalError => error
        raise error unless error.message.include?("host ABI result mismatch")
      end
    end
    raise "bad ABI result retried" unless host.calls == before + 2
    raise "public call after trap" unless vm.call_unboxed("direct", [0]) == 0x3f800000
  end
end

host = M5Host.new
hash = Wardite::HashModule.new({
  mix: ->(store, args) { host.mix(store, args) },
  echo64: ->(store, args) { host.echo64(store, args) }
})
[host, hash].each do |env|
  [[], [:all], [:frames]].each do |disabled|
    [false, true].each do |profile|
      instance = File.open(ARGV.fetch(0), "rb") do |file|
        Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false, engine: :efflorescence,
          import_object: {env: env}, disabled_optimizations: disabled, mir_profile: profile)
      end
      vm = instance.runtime
      raise "wrong runtime" unless vm.is_a?(Wardite::Efflorescence::VM)
      host.attach(vm)
      M5HostProbe.verify(vm, host, profile)
    end
  end
end
puts "M5 float host and indirect calls passed"
