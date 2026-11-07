# frozen_string_literal: true

require 'test_helper'
require_relative 'support/efflorescence_helper'
require_relative 'support/efflorescence_m2_cases'

class EfflorescenceM2GrowTest < Test::Unit::TestCase
  include EfflorescenceHelper
  include EfflorescenceM2Cases
  E = Wardite::Efflorescence

  class NoAllocation < E::StoreAccess
    attr_reader :requested
    def grown_buffer(_memory, delta)
      @requested = delta
      raise NoMemoryError, 'injected allocation failure'
    end
  end

  class BrokenAllocation < E::StoreAccess
    def grown_buffer(_memory, _delta)
      raise RuntimeError, 'implementation bug'
    end
  end

  test 'grow preserves bytes zero-fills new pages and honors declared max without mutating on failure' do
    bytes = compile_efflorescence_wat(GROW_WAT)
    MODES.each do |mode|
      fresh = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), engine: :efflorescence, enable_wasi: false, **mode)
      old = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false)
      vm = fresh.runtime
      memory = fresh.store.memories[0]
      assert_equal 1, vm.call_unboxed('size', [])
      original = memory.data
      assert_equal 1, vm.call_unboxed('grow', [0])
      old.runtime.call('grow', [0])
      assert_same original, memory.data
      [[1,1], [1,2], [1,0xffffffff], [0xffffffff,0xffffffff], [0,3]].each do |delta, expected|
        before = memory.data
        assert_equal expected, vm.call_unboxed('grow', [delta])
        assert_equal expected, old.runtime.call('grow', [delta]).value
        assert_equal old.store.memories[0].data, memory.data
        assert_equal old.store.memories[0].current, memory.current
        assert_equal memory.current * 65536, memory.data.bytesize
        assert_equal "abc".b, memory.data.byteslice(0,3)
        assert_equal Encoding::BINARY, memory.data.encoding
        assert_same before, memory.data if expected == 0xffffffff || delta == 0
      end
      assert_equal "\0".b * (2 * 65536), memory.data.byteslice(65536, 2 * 65536)
      assert_equal 0, vm.call_unboxed('load', [196607])
      assert_raise(Wardite::EvalError) { vm.call_unboxed('load', [196608]) }
      assert_equal 3, vm.call_unboxed('size', [])
    end
  end

  test 'undeclared max still enforces memory32 and injected allocation failure leaves both fields unchanged' do
    instance = load_efflorescence('(module (memory 0) (func (export "grow") (param i32) (result i32) local.get 0 memory.grow))')
    memory = instance.store.memories[0]
    probe = NoAllocation.new(instance.store)
    original = memory.data
    assert_equal 0xffffffff, probe.grow(65537)
    assert_nil probe.requested
    assert_equal 0xffffffff, probe.grow(65536)
    assert_equal 65536, probe.requested
    assert_equal 0xffffffff, probe.grow(1)
    assert_equal 0, memory.current
    assert_same original, memory.data
    assert_equal 0, memory.data.bytesize
    instance.runtime.instance_variable_set(:@store_access, probe)
    assert_equal 0xffffffff, instance.runtime.call_unboxed('grow', [1])
    instance.runtime.instance_variable_set(:@store_access, BrokenAllocation.new(instance.store))
    assert_raise(RuntimeError) { instance.runtime.call_unboxed('grow', [1]) }
    assert_same original, memory.data
    instance.runtime.instance_variable_set(:@store_access, E::StoreAccess.new(instance.store))
    assert_equal 0, instance.runtime.call_unboxed('grow', [1])
    assert_equal 65536, memory.data.bytesize
    assert_equal 1, memory.current
  end

  test 'callee growth does not leave a cached old buffer in its caller' do
    bytes = compile_efflorescence_wat(GROW_WAT)
    MODES.each do |mode|
      fresh = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), engine: :efflorescence, enable_wasi: false, **mode)
      3.times { assert_equal 53, fresh.runtime.call_unboxed('callee', []) }
      assert_equal 3, fresh.runtime.call_unboxed('size', [])
    end
  end
end
