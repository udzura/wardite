# frozen_string_literal: true
# rbs_inline: enabled

require 'wardite'
require_relative 'efflorescence_m2_probe'

class LimitedMemory < Wardite::Memory
  attr_reader :attempted_pages #: Array[Integer]

  def initialize
    super(1, 4)
    @attempted_pages = []
  end

  private

  # @rbs pages: Integer
  # @rbs return: IO::Buffer?
  def allocate_storage(pages)
    @attempted_pages << pages
    super(pages) if pages <= 2
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

    before = memory.buffer
    before_view = before.slice(65536, 1)
    before_view.set_value(:U8, 0, 42)
    raise 'spare capacity exposed through buffer size' unless before.size == 131072
    trapped = false
    begin
      M2Probe.call(vm, 'load', [131072])
    rescue Wardite::EvalError
      trapped = true
    end
    raise 'guest read spare capacity' unless trapped
    trapped = false
    begin
      before.set_value(:U8, 131072, 99)
    rescue ArgumentError
      trapped = true
    end
    raise 'host wrote to spare capacity' unless trapped
    before.locked do
      raise 'locked view allowed grow' unless M2Probe.call(vm, 'grow', [1]) == 0xffffffff
      raise 'locked view changed state' unless memory.current == 2 && memory.buffer.equal?(before)
    end
    raise 'max growth failed' unless M2Probe.call(vm, 'grow', [1]) == 2
    raise 'transfer left old views live' unless before.null? && !before_view.valid?
    raise 'transfer lost bytes' unless M2Probe.call(vm, 'load', [65536]) == 42
    raise 'transfer exposed nonzero bytes' unless M2Probe.call(vm, 'load', [131072]) == 0
    raise 'wrong size after transfer' unless M2Probe.call(vm, 'size', []) == 3 && memory.buffer.size == 196608
    before = memory.buffer
    raise 'missing max failure' unless M2Probe.call(vm, 'grow', [1]) == 0xffffffff
    raise 'failed grow changed state' unless memory.current == 3 && memory.buffer.equal?(before)
    raise 'oversized grow accepted' unless M2Probe.call(vm, 'grow', [0xffffffff]) == 0xffffffff
    raise 'caller cached data' unless M2Probe.call(vm, 'callee', []) == 53
  end
end

memory = Wardite::Memory.new(1, 5)
raise 'failed to reserve spare capacity' unless memory.grow(1) == 1
before = memory.buffer
before_view = before.slice(65536, 1)
before_view.set_value(:U8, 0, 42)
raise 'failed to grow beyond capacity' unless memory.grow(2) == 2
raise 'reallocation left old views live' unless before.null? && !before_view.valid?
raise 'reallocation lost bytes' unless Integer(memory.buffer.get_value(:U8, 65536)) == 42
raise 'reallocation exposed nonzero bytes' unless Integer(memory.buffer.get_value(:U8, 131072)) == 0

memory = LimitedMemory.new
memory.write_bytes(0, 'abc')
raise 'failed to retry without spare capacity' unless memory.grow(1) == 1 && memory.attempted_pages == [3, 2]
before = memory.buffer
raise 'allocation failure changed size' unless memory.grow(1) == -1 && memory.current == 2
raise 'wrong allocation attempts' unless memory.attempted_pages == [3, 2, 4, 3]
raise 'allocation failure changed buffer' unless memory.buffer.equal?(before) && memory.read_bytes(0, 3) == 'abc'

puts 'M2 grow passed'
