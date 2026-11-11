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
    original = memory.buffer
    old_view = original.slice(0, 1)
    raise 'wrong size' unless M2Probe.call(vm, 'size', []) == 1
    raise 'grow zero failed' unless M2Probe.call(vm, 'grow', [0]) == 1
    raise 'zero changed buffer' unless memory.buffer.equal?(original)
    original.locked do
      raise 'locked grow must fail' unless M2Probe.call(vm, 'grow', [1]) == 0xffffffff
      raise 'locked grow changed state' unless memory.current == 1 && memory.buffer.equal?(original)
    end
    raise 'growth failed' unless M2Probe.call(vm, 'grow', [1]) == 1
    raise 'old buffer or view remains usable' unless original.null? && !old_view.valid?
    raise 'old bytes lost' unless Integer(memory.buffer.get_value(:U8, 0)) == 97
    raise 'new bytes not zero' unless M2Probe.call(vm, 'load', [65536]) == 0
    raise 'wrong grown size' unless memory.current == 2 && memory.bytesize == 131072
    raise 'max growth failed' unless M2Probe.call(vm, 'grow', [1]) == 2
    before = memory.buffer
    raise 'missing max failure' unless M2Probe.call(vm, 'grow', [1]) == 0xffffffff
    raise 'failed grow changed state' unless memory.current == 3 && memory.buffer.equal?(before)
    raise 'oversized grow accepted' unless M2Probe.call(vm, 'grow', [0xffffffff]) == 0xffffffff
    raise 'caller cached data' unless M2Probe.call(vm, 'callee', []) == 53
  end
end
puts 'M2 grow passed'
