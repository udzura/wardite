# frozen_string_literal: true
# rbs_inline: enabled

require "wardite"
require_relative "efflorescence_m2_probe"

class GlobalSyncHost
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

  # @rbs store: Wardite::Store
  # @rbs args: Array[Wardite::wasmValue]
  # @rbs return: nil
  def update(store, args)
    global = store.globals.fetch(0)
    previous = global.value
    raise "host missed guest write" unless previous.is_a?(Wardite::I32) && previous.value == 10
    global.value = Wardite::I32.new(11)
    mode = args.fetch(0)
    raise "expected i32 argument" unless mode.is_a?(Wardite::I32)
    case mode.value
    when 1
      vm = @vm || raise("missing VM")
      raise "reentry missed host write" unless M2Probe.call(vm, "get", []) == 11
      M2Probe.call(vm, "set", [12])
      current = global.value
      raise "host missed reentrant write" unless current.is_a?(Wardite::I32) && current.value == 12
    when 2
      raise "host error"
    end
    nil
  end
end

host = GlobalSyncHost.new
instances = [] #: Array[Wardite::Instance]
2.times do
  instance = File.open(ARGV.fetch(0), "rb") do |file|
    Wardite::BinaryLoader.load_from_buffer(file, engine: :efflorescence, enable_wasi: false,
      import_object: {env: host})
  end
  instances << instance
end
first = instances.fetch(0)
second = instances.fetch(1)
vm = first.runtime
other_vm = second.runtime
raise "wrong engine" unless vm.is_a?(Wardite::Efflorescence::VM) && other_vm.is_a?(Wardite::Efflorescence::VM)
host.attach(vm)
global = first.store.globals.fetch(0)

initial = global.value
raise "start did not write back" unless initial.is_a?(Wardite::I32) && initial.value == 7
raise "initial read" unless M2Probe.call(vm, "get", []) == 7
raise "unchanged global was reboxed" unless global.value.equal?(initial)
raise "guest missed host write" unless M2Probe.call(vm, "through_host", [0]) == 11
raise "guest missed reentrant write" unless M2Probe.call(vm, "through_host", [1]) == 12

begin
  M2Probe.call(vm, "through_host", [2])
  raise "missing host error"
rescue RuntimeError => error
  raise unless error.message == "host error"
end
after_host = global.value
raise "host write was lost during unwinding" unless after_host.is_a?(Wardite::I32) && after_host.value == 11

begin
  M2Probe.call(vm, "trap", [])
  raise "missing trap"
rescue Wardite::Unreachable => error
  raise unless error.message.include?("unreachable")
end
after_trap = global.value
raise "trap did not write back" unless after_trap.is_a?(Wardite::I32) && after_trap.value == 21

begin
  M2Probe.call(vm, "throw", [])
  raise "missing uncaught Wasm exception"
rescue Wardite::UncaughtWasmException
end
after_throw = global.value
raise "uncaught Wasm exception did not write back" unless after_throw.is_a?(Wardite::I32) && after_throw.value == 31

# Share the same Global through the Store API.
second.store.globals[0] = global
raise "second VM missed first VM write" unless M2Probe.call(other_vm, "get", []) == 31
M2Probe.call(other_vm, "set", [0xffffffff])
raise "first VM missed second VM write" unless M2Probe.call(vm, "get", []) == 0xffffffff

M2Probe.call(vm, "set_typed", [])
i64_min = -9223372036854775807 - 1
f32_bits = 0xffc12345
f64_bits = -0x7543210fedcbb
i64 = first.store.globals.fetch(1).value
f32 = first.store.globals.fetch(2).value
f64 = first.store.globals.fetch(3).value
raise "i64 store bits" unless i64.is_a?(Wardite::I64) && i64.value_s == i64_min
raise "f32 store bits" unless f32.is_a?(Wardite::F32) && f32.raw_bits == f32_bits
raise "f64 store bits" unless f64.is_a?(Wardite::F64) && f64.raw_bits == f64_bits
raise "i64 register bits" unless M2Probe.call(vm, "get_i64", []) == i64_min
raise "f32 register bits" unless M2Probe.call(vm, "get_f32_bits", []) == f32_bits
raise "f64 register bits" unless M2Probe.call(vm, "get_f64_bits", []) == f64_bits
puts "global synchronization passed"
