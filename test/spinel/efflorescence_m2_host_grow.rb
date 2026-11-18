# frozen_string_literal: true
# rbs_inline: enabled

require 'wardite'
require_relative 'efflorescence_m2_probe'

class M2GrowHost
  include Wardite::WasmModule

  def initialize
    @vm = nil #: Wardite::Efflorescence::VM?
  end

  # @rbs vm: Wardite::Efflorescence::VM
  def attach(vm)
    @vm = vm
  end

  # @rbs store: Wardite::Store
  # @rbs args: Array[Wardite::wasmValue]
  # @rbs return: nil
  def grow(store, args)
    address = args.fetch(0).value.to_i
    memory = store.memories.fetch(0)
    raise 'host grow failed' unless memory.grow(1) == address / 65536
    memory.write_bytes(address, "\x80".b)
    if address == 131072
      vm = @vm || raise('missing runtime')
      raise 'reentry missed grown memory' unless M2Probe.call(vm, 'read', [address]) == 128
    end
    nil
  end
end

host = M2GrowHost.new
instance = File.open(ARGV.fetch(0), 'rb') do |file|
  Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false, engine: :efflorescence, import_object: {env: host})
end
vm = instance.runtime
raise 'wrong engine' unless vm.is_a?(Wardite::Efflorescence::VM)
host.attach(vm)
raise 'caller missed host grow' unless M2Probe.call(vm, 'run', [65536]) == 382
raise 'caller missed grow across reentry' unless M2Probe.call(vm, 'run', [131072]) == 382
puts 'M2 host grow passed'
