# frozen_string_literal: true
# rbs_inline: enabled

require 'wardite'
require_relative 'efflorescence_m2_probe'

[[], [:all], [:frames]].each do |disabled|
  [false, true].each do |profile|
    instance = File.open(ARGV.fetch(0), 'rb') do |file|
      Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false, engine: :efflorescence,
        disabled_optimizations: disabled, mir_profile: profile)
    end
    vm = instance.runtime
    raise 'wrong engine' unless vm.is_a?(Wardite::Efflorescence::VM)
    memory = instance.store.memories[0] || raise('missing memory')
    raise 'start memory not initialized' unless M2Probe.call(vm, 'load', [0]) == 11
    raise 'start global not initialized' unless M2Probe.call(vm, 'get', []) == 5
    2.times do
      raise 'catch rolled back Store' unless M2Probe.call(vm, 'caught', []) == 51
      raise 'global write lost' unless M2Probe.call(vm, 'get', []) == 2
      before = memory.read_bytes(65532,4)
      trapped = false
      begin
        M2Probe.call(vm, 'trap', [])
      rescue Wardite::EvalError
        trapped = true
      end
      raise 'catch_all caught a memory trap' unless trapped
      raise 'partial failing store' unless memory.read_bytes(65532,4) == before && memory.bytesize == 65536
      raise 'completed global update rolled back' unless M2Probe.call(vm, 'get', []) == 31
      raise 'completed store rolled back' unless M2Probe.call(vm, 'load', [8]) == 73
      caught = false
      begin
        M2Probe.call(vm, 'uncaught', [])
      rescue Wardite::UncaughtWasmException => error
        raise 'lost payload' unless error.payload == [17]
        raise 'wrong tag' unless error.tag.equal?(instance.tags[0])
        caught = true
      end
      raise 'missing uncaught exception' unless caught
      raise 'uncaught rollback' unless M2Probe.call(vm, 'get', []) == 99
      raise 'uncaught memory rollback' unless M2Probe.call(vm, 'load', [12]) == 44
      raise 'load snapshot changed' unless M2Probe.call(vm, 'snapshot', []) == 0xffffffd8
      raise 'stale reused local' unless M2Probe.call(vm, 'reuse', []) == 0
      raise 'stale reused store' unless M2Probe.call(vm, 'load', [20]) == 0
      raise 'pure i32 failed' unless M2Probe.call(vm, 'pure', []) == 42
    end
  end
end
puts 'M2 integration passed'
