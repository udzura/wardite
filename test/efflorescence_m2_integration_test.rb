# frozen_string_literal: true

require 'test_helper'
require_relative 'support/efflorescence_helper'
require_relative 'support/efflorescence_m2_cases'

class EfflorescenceM2IntegrationTest < Test::Unit::TestCase
  include EfflorescenceHelper
  include EfflorescenceM2Cases
  E = Wardite::Efflorescence

  test 'start exports EH updates memory traps uncaught recovery and frame reuse share one Store' do
    bytes = compile_efflorescence_wat(INTEGRATION_WAT)
    MODES.each do |mode|
      fresh = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), engine: :efflorescence, enable_wasi: false, **mode)
      vm = fresh.runtime
      memory = fresh.store.memories[0]
      assert_same memory, fresh.exports.mappings.fetch('memory')[1]
      assert_same fresh.store.globals[0], fresh.exports.mappings.fetch('g')[1]
      assert_equal 11, vm.call_unboxed('load',[0])
      assert_equal 5, vm.call_unboxed('get',[])
      2.times do
        assert_equal 51, vm.call_unboxed('caught',[])
        assert_equal 2, vm.call_unboxed('get',[])
        assert_equal 40, vm.call_unboxed('load',[4])
        before = memory.data.byteslice(65532,4)
        assert_raise(Wardite::EvalError) { vm.call_unboxed('trap',[]) }
        assert_equal before, memory.data.byteslice(65532,4)
        assert_equal 65536, memory.data.bytesize
        assert_equal 31, vm.call_unboxed('get',[])
        assert_equal 73, vm.call_unboxed('load',[8])
        error = assert_raise(Wardite::UncaughtWasmException) { vm.call_unboxed('uncaught',[]) }
        assert_equal [17], error.payload
        assert_equal 99, vm.call_unboxed('get',[])
        assert_equal 44, vm.call_unboxed('load',[12])
        assert_equal 0xffffffd8, vm.call_unboxed('snapshot',[])
        assert_equal 50, vm.call_unboxed('load',[16])
        assert_equal 0, vm.call_unboxed('reuse',[])
        assert_equal 0, vm.call_unboxed('load',[20])
        assert_equal 42, vm.call_unboxed('pure',[])
      end
      vm.semantic_ir.functions.each_with_index do |fn,i|
        next unless fn.uses_store || fn.uses_eh
        assert_equal fn.instructions.map(&:operands), vm.optimized_ir.function_at(i).instructions.map(&:operands)
      end
      if mode != {disabled_optimizations: [:all]}
        pure = fresh.export_section.exports.fetch('pure').index
        assert vm.optimized_ir.function_at(pure).instructions.none? { |insn| insn[0] == E::Opcode::CALL }
        reuse = fresh.export_section.exports.fetch('reuse').index
        assert vm.optimized_ir.function_at(reuse).instructions.any? { |insn| insn[0] == E::Opcode::CALL }
      end
    end
  end

  test 'zero-memory endpoints and zero declared maximum are valid without allowing extension' do
    wat = <<~WAT
      (module (memory 0 0) (data "")
        (func (export "grow") (param i32) (result i32) local.get 0 memory.grow)
        (func (export "copy") (param i32 i32 i32) local.get 0 local.get 1 local.get 2 memory.copy)
        (func (export "fill") (param i32 i32 i32) local.get 0 local.get 1 local.get 2 memory.fill)
        (func (export "init") (param i32 i32 i32) local.get 0 local.get 1 local.get 2 memory.init 0))
    WAT
    bytes = compile_efflorescence_wat(wat)
    MODES.each do |mode|
      vm = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), engine: :efflorescence, enable_wasi: false, **mode).runtime
      assert_equal 0, vm.call_unboxed('grow',[0])
      assert_equal 0xffffffff, vm.call_unboxed('grow',[1])
      %w[copy fill init].each do |name|
        assert_nil vm.call_unboxed(name,[0,0,0])
        assert_raise(Wardite::EvalError) { vm.call_unboxed(name,[1,0,0]) }
      end
      assert_equal '', vm.instance.store.memories[0].data
      assert_equal 0, vm.instance.store.memories[0].current
    end
  end

  test 'loader detects malformed global flags data counts and truncated data and memargs' do
    payload = [1,0x7f,2,0x41,0,0x0b]
    bytes = "\0asm\x01\0\0\0".b + [6,payload.size,*payload].pack('C*')
    assert_raise(Wardite::LoadError) { Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false) }
    bytes = compile_efflorescence_wat(BULK_WAT)
    wrong_count = bytes.sub("\x0c\x01\x03".b, "\x0c\x01\x04".b)
    assert_not_equal bytes, wrong_count
    truncated_data = "\0asm\x01\0\0\0".b + [11,5,1,1,3,97,98].pack('C*')
    [wrong_count, truncated_data].each do |bad|
      assert_raise(Wardite::LoadError) { Wardite::BinaryLoader.load_from_buffer(StringIO.new(bad), enable_wasi: false, engine: :efflorescence) }
    end
    # A valid multi-memory memarg flag cannot be mistaken for an alignment.
    assert_raise(Wardite::LoadError) { Wardite::BinaryLoader.code_body(StringIO.new([0x28,0x40,0,0,0x0b].pack('C*'))) }
  end
end
