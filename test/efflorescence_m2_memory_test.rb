# frozen_string_literal: true

require 'test_helper'
require_relative 'support/efflorescence_helper'
require_relative 'support/efflorescence_m2_cases'

class EfflorescenceM2MemoryTest < Test::Unit::TestCase
  include EfflorescenceHelper
  include EfflorescenceM2Cases
  LOADS = {'load' => [4, 0x8001ff80], 'load8_s' => [1, 0xffffff80], 'load8_u' => [1, 128],
           'load16_s' => [2, 0xffffff80], 'load16_u' => [2, 0xff80]}.freeze
  STORES = {'store' => 4, 'store8' => 1, 'store16' => 2}.freeze
  WAT = EfflorescenceM2Cases::MEMORY_WAT

  def instance(bytes, **options)
    Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), engine: :efflorescence, enable_wasi: false, **options)
  end

  def snapshot(memory)
    [memory.data.dup, memory.data.bytesize, memory.current]
  end

  test 'all load widths signs unaligned bytes offsets and endpoint bounds' do
    bytes = compile_efflorescence_wat(WAT)
    MODES.each do |mode|
      fresh = instance(bytes, **mode)
      vm = fresh.runtime
      memory = fresh.store.memories[0]
      LOADS.each do |name, (width, expected)|
        memory.data[1, 4] = [128, 255, 1, 128].pack('C*')
        memory.data[65536 - width, width] = [128, 255, 1, 128].first(width).pack('C*')
        assert_equal expected, vm.call_unboxed(name, [1]), "unaligned #{name} #{mode}"
        assert_equal expected, vm.call_unboxed(name, [65536 - width]), "last valid #{name}"
        before = snapshot(memory)
        [65537 - width, 65536, -1].each do |address|
          assert_raise(Wardite::EvalError) { vm.call_unboxed(name, [address]) }
          assert_equal before, snapshot(memory)
        end
      end
      memory.data[4, 4] = [128, 255, 1, 128].pack('C*')
      assert_equal 0x8001ff80, vm.call_unboxed('offset', [1])
      [1, -1].each { |address| assert_raise(Wardite::EvalError) { vm.call_unboxed('overflow', [address]) } }
      assert_raise(Wardite::EvalError) { vm.call_unboxed('unused', []) }
      assert_equal 65536, memory.data.bytesize
      assert_equal 1, memory.current
      assert_equal Encoding::BINARY, memory.data.encoding
    end
  end

  test 'stores truncate little-endian values and cannot partially update or extend memory on traps' do
    bytes = compile_efflorescence_wat(WAT)
    MODES.each do |mode|
      fresh = instance(bytes, **mode)
      vm = fresh.runtime
      memory = fresh.store.memories[0]
      STORES.each do |name, width|
        [0x89abcdef, 0xffffffff, 0].each do |value|
          expected = 4.times.map { |i| (value >> (8 * i)) & 255 }.first(width)
          [1, 65536 - width].each do |address|
            assert_nil vm.call_unboxed(name, [address, value])
            assert_equal expected, memory.data.byteslice(address, width).bytes
            assert_equal 65536, memory.data.bytesize
          end
        end
        before = snapshot(memory)
        [65537 - width, 65536, -1].each do |address|
          assert_raise(Wardite::EvalError) { vm.call_unboxed(name, [address, 0x12345678]) }
          assert_equal before, snapshot(memory), "#{name}(#{address})"
        end
      end
      before = snapshot(memory)
      [1, -1].each { |address| assert_raise(Wardite::EvalError) { vm.call_unboxed('store_overflow', [address]) } }
      assert_equal before, snapshot(memory)
    end
  end

  test 'normal loads stores and whole memory agree with independent stack instances' do
    bytes = compile_efflorescence_wat(WAT)
    MODES.each do |mode|
      fresh = instance(bytes, **mode)
      old = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false)
      STORES.each_key do |name|
        [1, 17, 100].each do |address|
          fresh.runtime.call_unboxed(name, [address, 0x89abcdef])
          old.runtime.call(name, [address, 0x89abcdef])
          assert_equal old.store.memories[0].data, fresh.store.memories[0].data
          assert_equal old.store.memories[0].current, fresh.store.memories[0].current
          LOADS.each_key do |load|
            assert_equal old.runtime.call(load, [address]).value, fresh.runtime.call_unboxed(load, [address])
          end
        end
      end
    end
  end
end
