# frozen_string_literal: true
# rbs_inline: enabled

require 'wardite'
require_relative 'efflorescence_m2_probe'

class M2BulkProbe
  # @rbs vm: Wardite::Efflorescence::VM
  # @rbs memory: Wardite::Memory
  # @rbs name: String
  # @rbs arguments: Array[Object]
  # @rbs return: void
  def self.unchanged_trap(vm, memory, name, arguments)
    before = memory.data.dup
    trapped = false
    begin
      M2Probe.call(vm, name, arguments)
    rescue Wardite::EvalError
      trapped = true
    end
    raise 'missing bulk bounds trap' unless trapped
    raise 'partial bulk update' unless memory.data == before && memory.data.bytesize == 65536 && memory.current == 1
  end
end

[[], [:all], [:frames]].each do |disabled|
  [false, true].each do |profile|
    instance = File.open(ARGV.fetch(0), 'rb') do |file|
      Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false, engine: :efflorescence,
        disabled_optimizations: disabled, mir_profile: profile)
    end
    vm = instance.runtime
    raise 'wrong engine' unless vm.is_a?(Wardite::Efflorescence::VM)
    memory = instance.store.memories[0] || raise('missing memory')
    M2Probe.call(vm, 'init', [100,0,9])
    raise 'bad passive bytes' unless memory.data.byteslice(100,9) == "\x80\xffABC\0xyz".b
    M2Probe.call(vm, 'init', [200,0,9])
    raise 'passive segment consumed' unless memory.data.byteslice(200,9) == "\x80\xffABC\0xyz".b
    M2Probe.call(vm, 'active', [65536,0,0])
    M2Probe.call(vm, 'empty', [65536,0,0])
    M2BulkProbe.unchanged_trap(vm, memory, 'active', [0,0,1])
    M2BulkProbe.unchanged_trap(vm, memory, 'empty', [0,1,0])
    M2BulkProbe.unchanged_trap(vm, memory, 'init', [0,8,2])
    M2BulkProbe.unchanged_trap(vm, memory, 'init', [65528,0,9])
    M2BulkProbe.unchanged_trap(vm, memory, 'init', [0,10,0])
    memory.data[0,16] = '0123456789abcdef'.b
    M2Probe.call(vm, 'copy', [2,0,8])
    raise 'forward overlap failed' unless memory.data.byteslice(0,16) == '0101234567abcdef'.b
    memory.data[0,16] = '0123456789abcdef'.b
    M2Probe.call(vm, 'copy', [0,2,8])
    raise 'backward overlap failed' unless memory.data.byteslice(0,16) == '2345678989abcdef'.b
    M2Probe.call(vm, 'copy', [0,0,65536])
    M2Probe.call(vm, 'copy', [65536,65536,0])
    M2BulkProbe.unchanged_trap(vm, memory, 'copy', [0,65535,2])
    M2BulkProbe.unchanged_trap(vm, memory, 'copy', [65535,0,2])
    M2BulkProbe.unchanged_trap(vm, memory, 'copy', [0,65537,0])
    M2BulkProbe.unchanged_trap(vm, memory, 'copy', [65537,0,0])
    [0,255,256,0xffffffff].each do |value|
      M2Probe.call(vm, 'fill', [65530,value,6])
      raise 'fill byte mask failed' unless memory.data.getbyte(65535) == (value & 255)
      raise 'fill changed memory size' unless memory.data.bytesize == 65536
      M2Probe.call(vm, 'fill', [65536,value,0])
    end
    M2BulkProbe.unchanged_trap(vm, memory, 'fill', [65535,42,2])
    M2BulkProbe.unchanged_trap(vm, memory, 'fill', [65537,42,0])
    M2BulkProbe.unchanged_trap(vm, memory, 'fill', [0,42,0xffffffff])
  end
end
puts 'M2 bulk passed'
