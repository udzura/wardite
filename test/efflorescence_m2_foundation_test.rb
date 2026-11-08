# frozen_string_literal: true

require 'test_helper'
require_relative 'support/efflorescence_helper'

class EfflorescenceM2FoundationTest < Test::Unit::TestCase
  include EfflorescenceHelper
  E = Wardite::Efflorescence
  OP = E::Opcode

  test 'checked ranges include zero-length endpoints and reject unsigned overflow' do
    [[0, 0, 0], [16, 0, 16], [15, 1, 16], [0, 16, 16]].each do |start, length, size|
      assert_nothing_raised { E::StoreAccess.check_range(start, length, size) }
    end
    [[1, 0, 0], [17, 0, 16], [-1, 1, 16], [0, -1, 16], [15, 2, 16],
     [0xffffffff + 1, 4, 65536], [0xffffffff, 1, 65536]].each do |start, length, size|
      assert_raise(Wardite::EvalError) { E::StoreAccess.check_range(start, length, size) }
    end
  end

  test 'memory site tables participate in copying reads renaming validation and inspection' do
    function = E::Function.new(0, [:i32, :i32, :i32], [], 0)
    function.uses_store = true
    function.memory_sites << E::MemorySite.new([0, 1, 2], data_index: 3)
    function.instructions << E::Instruction.new([OP::MEMORY_INIT, 0])
    function.instructions << E::Instruction.new([OP::RETURN, -1])
    E::RegisterValidation.new.validate(function)
    assert_equal [0, 1, 2], function.reads(function.instructions[0])
    assert_equal [1, 1, 1], E::Analysis.new(function).reads
    assert_equal(-1, OP.destination(function.instructions[0]))
    assert OP.may_trap?(OP::MEMORY_INIT)
    assert_false OP.may_throw?(OP::MEMORY_INIT)
    copy = E::Optimizer.new(E::Configuration.new([])).optimize(E::IR.new([function])).function_at(0)
    assert copy.uses_store
    assert_not_same function.memory_sites[0], copy.memory_sites[0]
    copy.replace_register_references!([2, 1, 0])
    assert_equal [2, 1, 0], copy.memory_sites[0].sources
    assert_equal [0, 1, 2], function.memory_sites[0].sources
    assert_include E::Inspection.new.disassemble(E::IR.new([copy])), 'memory 0: sources=[2, 1, 0]'
    assert_include E::Inspection.new.disassemble(E::IR.new([copy])), 'data=3'
    assert OP.reads_store?(OP::I32_LOAD)
    assert OP.writes_store?(OP::I32_STORE)
    assert_false OP.reads_store?(OP::I32_ADD)
    assert_equal(-1, OP.destination(E::Instruction.new([OP::I32_STORE, 0, 1, 0])))
  end

  test 'table operands cannot read undefined or reference-typed registers' do
    function = E::Function.new(0, [], [], 0)
    slot = function.allocate_register(0)
    function.memory_sites << E::MemorySite.new([slot, slot, slot])
    function.instructions << E::Instruction.new([OP::MEMORY_FILL, 0])
    function.instructions << E::Instruction.new([OP::RETURN, -1])
    assert_raise(E::TranslationError) { E::RegisterValidation.new.validate(function) }
    function = E::Function.new(0, [], [], 1, local_types: [:exnref])
    function.memory_sites << E::MemorySite.new([0, 0, 0])
    function.instructions << E::Instruction.new([OP::MEMORY_COPY, 0])
    function.instructions << E::Instruction.new([OP::RETURN, -1])
    assert_raise(E::TranslationError) { E::RegisterValidation.new.validate(function) }
  end

  test 'memory global and data indices and alignments are validated even in dead code' do
    cases = {
      '(module (func unreachable i32.load drop))' => 'requires memory',
      '(module (func unreachable global.get 0 drop))' => 'invalid global index',
      '(module (global i32 (i32.const 0)) (func unreachable i32.const 1 global.set 0))' => 'immutable',
      '(module (memory 1) (func unreachable memory.size 1 drop))' => 'only memory 0',
      '(module (memory 1) (func unreachable i32.load align=8 drop))' => 'alignment',
      '(module (memory 1) (func unreachable memory.init 0))' => 'invalid data index',
      '(module (memory 1) (data "x") (func unreachable memory.init 1))' => 'invalid data index'
    }
    cases.each do |wat, text|
      error = assert_raise(E::TranslationError, E::UnsupportedFeature) { load_efflorescence(wat) }
      assert_include error.message, text
    end
    bytes = compile_efflorescence_wat('(module (memory 1) (data "x") (func unreachable memory.init 0))')
    missing_count = bytes.sub("\x0c\x01\x01".b, ''.b)
    assert_not_equal bytes, missing_count
    error = assert_raise(E::TranslationError) do
      Wardite::BinaryLoader.load_from_buffer(StringIO.new(missing_count), engine: :efflorescence, enable_wasi: false)
    end
    assert_include error.message, 'data count'
    error = assert_raise(E::UnsupportedFeature) do
      load_efflorescence('(module (global f64 (f64.const 42)) (func unreachable global.get 0 drop))')
    end
    assert_include error.message, 'only i32/i64 global'
  end

  test 'shared limits reject unsupported flags and invalid page bounds before allocation' do
    [[1, 3, 0, 1], [1, 2, 0, 1], [1, 4, 0], [1, 8, 0], [1, 1, 1, 0], [1, 0, 0x81, 0x80, 4]].each do |payload|
      bytes = "\0asm\x01\0\0\0".b + [5, payload.size, *payload].pack('C*')
      [:stack, :efflorescence].each do |engine|
        assert_raise(Wardite::LoadError) do
          Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false, engine: engine)
        end
      end
    end
    assert_nothing_raised { load_efflorescence('(module (memory 0 0))') }
  end

  test 'shared initialization uses binary bytes and decodes end-valued LEB operands correctly' do
    bytes = compile_efflorescence_wat('(module (memory (export "memory") 1) (data (i32.const 11) "\ff\c3\a9") (global (export "g") i32 (i32.const 11)))')
    [:stack, :efflorescence].each do |engine|
      instance = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false, engine: engine)
      memory = instance.store.memories[0]
      assert_equal Encoding::BINARY, memory.data.encoding
      assert_equal 65536, memory.data.bytesize
      assert_equal [255, 195, 169], memory.data.byteslice(11, 3).bytes
      assert_equal 11, instance.store.globals[0].value.value
    end
    ['(module (data (i32.const 0) "x"))',
     '(module (memory 1) (data (i32.const -1) "x"))',
     '(module (memory 1) (data (i32.const 65536) "x"))'].each do |wat|
      assert_raise(Wardite::LoadError) { load_efflorescence(wat) }
    end
  end
end
