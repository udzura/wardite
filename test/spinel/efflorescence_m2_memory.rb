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
    memory.data[1, 4] = [128, 255, 1, 128].pack('C*')
    %w[load load8_s load8_u load16_s load16_u].each_with_index do |name, i|
      expected = [0x8001ff80, 0xffffff80, 128, 0xffffff80, 0xff80][i]
      raise "bad #{name}" unless M2Probe.call(vm, name, [1]) == expected
      width = [4, 1, 1, 2, 2][i] || raise('missing width')
      memory.data[65536 - width, width] = [128, 255, 1, 128].pack('C*').byteslice(0, width)
      raise 'bad endpoint load' unless M2Probe.call(vm, name, [65536 - width]) == expected
      trapped = false
      begin
        M2Probe.call(vm, name, [65537 - width])
      rescue Wardite::EvalError
        trapped = true
      end
      raise 'missing load trap' unless trapped
    end
    [['load8_s', 127, 127], ['load8_s', 128, 0xffffff80],
     ['load8_u', 127, 127], ['load8_u', 128, 128],
     ['load16_s', 32767, 32767], ['load16_s', 32768, 0xffff8000],
     ['load16_u', 32767, 32767], ['load16_u', 32768, 32768]].each do |name, value, expected|
      memory.data[1, 2] = [value & 255, value >> 8].pack('C*')
      raise 'bad sign boundary' unless M2Probe.call(vm, name, [1]) == expected
    end
    %w[store store8 store16].each_with_index do |name, i|
      width = [4, 1, 2][i] || raise('missing width')
      M2Probe.call(vm, name, [1, 0x89abcdef])
      raise 'bad low byte' unless memory.data.getbyte(1) == 239
      M2Probe.call(vm, name, [65536 - width, 0xffffffff])
      raise 'bad endpoint store' unless memory.data.getbyte(65535) == 255
      before = memory.data.dup
      trapped = false
      begin
        M2Probe.call(vm, name, [65537 - width, 0x12345678])
      rescue Wardite::EvalError
        trapped = true
      end
      raise 'missing store trap' unless trapped
      raise 'partially updated memory' unless memory.data == before && memory.data.bytesize == 65536 && memory.current == 1
    end
    %w[overflow store_overflow unused].each do |name|
      trapped = false
      begin
        M2Probe.call(vm, name, name == 'unused' ? [] : [1])
      rescue Wardite::EvalError
        trapped = true
      end
      raise 'lost address/trap semantics' unless trapped
    end
  end
end
puts 'M2 memory passed'
