# frozen_string_literal: true
# rbs_inline: enabled

require "wardite"
require_relative "efflorescence_m2_probe"

class M3Host
  include Wardite::WasmModule

  # @rbs args: Array[Wardite::wasmValue]
  # @rbs return: Integer
  def self.sum(args)
    left, right = args
    raise "unboxed host args" unless left.is_a?(Wardite::I32) && right.is_a?(Wardite::I32)
    left.value + right.value
  end

  # @rbs store: Wardite::Store
  # @rbs return: void
  def self.write_guest_memory(store)
    memory = store.memories[0] || raise("missing guest memory")
    memory.buffer.set_value(:U8, 0, 90)
    raise "host read did not observe the write" unless memory.read_bytes(0, 1) == "Z".b
  end

  def sum(store, args)
    M3Host.write_guest_memory(store)
    M3Host.sum(args)
  end

  def wrong(_store, _args)
    raise "mismatched host called"
  end
end

host = M3Host.new
hash = Wardite::HashModule.new({
  sum: ->(store, args) do
    M3Host.write_guest_memory(store)
    Wardite::I32.new(M3Host.sum(args))
  end,
  wrong: ->(_store, _args) { raise "mismatched hash host called" }
})
[host, hash].each do |env|
  [[], [:all], [:frames]].each do |disabled|
    [false, true].each do |profile|
      instance = File.open(ARGV.fetch(0), "rb") do |file|
        Wardite::BinaryLoader.load_from_buffer(file, engine: :efflorescence, enable_wasi: false,
          import_object: {env: env}, disabled_optimizations: disabled, mir_profile: profile)
      end
      vm = instance.runtime
      raise "wrong engine" unless vm.is_a?(Wardite::Efflorescence::VM)
      raise "host reexport" unless M2Probe.call(vm, "sum", [15, 6]) == 21
      raise "direct host" unless M2Probe.call(vm, "direct", [15, 6]) == 21
      raise "guest did not observe host write" unless M2Probe.call(vm, "read_host_byte", []) == 90
      raise "indirect defined" unless M2Probe.call(vm, "run", [5, 15, 6]) == 9
      raise "indirect host" unless M2Probe.call(vm, "run", [1, 15, 6]) == 21
      begin
        M2Probe.call(vm, "run", [2, 15, 6])
        raise "missing type trap"
      rescue Wardite::EvalError => error
        raise "wrong trap" unless error.message.include?("type mismatch")
      end
      table = instance.store.tables[0] || raise("missing table")
      table.refs[1] = table.refs[5]
      raise "stale table" unless M2Probe.call(vm, "run", [1, 15, 6]) == 9
    end
  end
end
puts "M3 host and indirect calls passed"
