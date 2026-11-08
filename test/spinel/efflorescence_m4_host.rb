# frozen_string_literal: true
# rbs_inline: enabled

require "wardite"
require_relative "efflorescence_m2_probe"

class M4Host
  include Wardite::WasmModule

  # @rbs @vm: Wardite::Efflorescence::VM?

  def initialize
    @vm = nil
  end

  # @rbs vm: Wardite::Efflorescence::VM
  # @rbs return: void
  def attach(vm)
    @vm = vm
  end

  # @rbs args: Array[Wardite::wasmValue]
  # @rbs return: Wardite::wasmFuncReturn
  def mix(_store, args)
    left, mode, right = args
    unless left.is_a?(Wardite::I64) && mode.is_a?(Wardite::I32) && right.is_a?(Wardite::I64) && right.value_s == 9
      raise "invalid mixed argument order"
    end
    case mode.value
    when 0 then left.value_s - 9
    when 1
      vm = @vm || raise("missing runtime")
      M2Probe.call(vm, "echo", [left])
    when 2
      vm = @vm || raise("missing runtime")
      begin
        M2Probe.call(vm, "fail", [])
        raise "missing nested trap"
      rescue Wardite::Unreachable
        Wardite::I64(-1)
      end
    else Wardite::I32(1)
    end
  end

  def zero(_store, args)
    raise "zero arity" unless args.empty?
    Wardite::I64(-1)
  end

  def one(_store, args)
    value = args[0]
    raise "one i64 argument" unless value.is_a?(Wardite::I64) && value.value_s == -1
    Wardite::I32(17)
  end

  def sink(_store, args)
    value = args[0]
    raise "one i64 argument" unless value.is_a?(Wardite::I64)
    value.value_s == 0 ? nil : Wardite::I64(-1)
  end
end

host = M4Host.new
hash = Wardite::HashModule.new({
  mix: ->(store, args) { host.mix(store, args) },
  zero: ->(store, args) { host.zero(store, args) },
  one: ->(store, args) { host.one(store, args) },
  sink: ->(store, args) { host.sink(store, args) }
})
[host, hash].each do |env|
  instance = File.open(ARGV.fetch(0), "rb") do |file|
    Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false, engine: :efflorescence,
      import_object: { env: env }, mir_profile: true)
  end
  vm = instance.runtime
  raise "wrong runtime" unless vm.is_a?(Wardite::Efflorescence::VM)
  host.attach(vm)
  min = -9223372036854775807 - 1
  raise "zero result" unless M2Probe.call(vm, "zero", []) == -1
  raise "one result" unless M2Probe.call(vm, "one", [-1]) == 17
  raise "void result" unless M2Probe.call(vm, "sink", [0]).nil?
  raise "reexport result" unless M2Probe.call(vm, "mix", [-1, 0, 9]) == -10
  raise "direct result" unless M2Probe.call(vm, "direct", [-1, 0]) == -10
  raise "indirect host result" unless M2Probe.call(vm, "indirect", [0, -1, 0]) == -10
  raise "indirect defined result" unless M2Probe.call(vm, "indirect", [1, -1, 0]) == -10
  begin
    M2Probe.call(vm, "indirect", [2, -1, 0])
    raise "missing type mismatch"
  rescue Wardite::EvalError => error
    raise error unless error.message.include?("function type mismatch")
  end
  begin
    M2Probe.call(vm, "direct", [-1, 3])
    raise "missing ABI trap"
  rescue Wardite::EvalError => error
    raise error unless error.message.include?("host ABI result mismatch")
  end
  raise "nested result" unless M2Probe.call(vm, "outer", [min, 1]) == 0
  raise "recovery result" unless M2Probe.call(vm, "outer", [-1, 2]) == 0
end
puts "M4 host calls passed"
