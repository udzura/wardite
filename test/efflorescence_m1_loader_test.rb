# frozen_string_literal: true

require 'test_helper'
require_relative 'support/efflorescence_helper'
require_relative 'support/legacy_wasm_decode'
require 'tempfile'

class EfflorescenceM1LoaderTest < Test::Unit::TestCase
  include EfflorescenceHelper
  E = Wardite::Efflorescence

  def load_wat(wat, engine: :efflorescence)
    Wardite::BinaryLoader.load_from_buffer(StringIO.new(compile_efflorescence_wat(wat)), enable_wasi: false, engine: engine)
  end

  test 'stack engine rejects new features before Store initialization' do
    cases = [
      '(module (tag))',
      '(module (func (local exnref)))',
      '(module (func try_table end))',
      '(module (type (func (result i32 i32))) (func block (type 0) i32.const 1 i32.const 2 end drop drop))',
      '(module (func block (result exnref) unreachable end drop))'
    ]
    cases.each do |wat|
      stored = false
      trace = TracePoint.new(:call) { |event| stored = true if event.defined_class == Wardite::Store && event.method_id == :initialize }
      trace.enable { assert_raise(Wardite::LoadError) { load_wat(wat, engine: :stack) } }
      assert_false stored, wat
    ensure
      trace&.disable
    end
    # Existing numeric block forms remain available in the stack engine.
    assert_nothing_raised { load_wat('(module (func block (result i64) i64.const 1 end drop))', engine: :stack) }
  end

  test 'unsupported tag and reference features are rejected including dead unexported functions' do
    [
      '(module (import "host" "e" (tag)))',
      '(module (tag (export "e")))',
      '(module (type (func (result i32))) (tag (type 0)))',
      '(module (func (param exnref)))',
      '(module (func (result exnref) unreachable))',
      '(module (func (local (ref exn))))',
      '(module (func unreachable block (param i32) end))',
      '(module (func unreachable block (result funcref) end))'
    ].each { |wat| assert_raise(Wardite::LoadError, E::UnsupportedFeature) { load_wat(wat) } }
  end

  test 'new structures validate indices depths and payload label types internally' do
    [
      '(module (func unreachable throw 0))',
      '(module (tag) (func try_table (catch 1 0) end))',
      '(module (tag) (func try_table (catch 0 9) end))',
      '(module (tag (param i32)) (func block try_table (catch 0 0) end end))',
      '(module (tag) (func block (result i32) try_table (catch 0 0) end unreachable end drop))',
      '(module (func block (result i32) try_table (catch_all_ref 0) end unreachable end drop))',
      '(module (func unreachable local.get 0))',
      '(module (tag) (func (local exnref) local.get 0 i32.eqz drop))',
      '(module (func (local exnref) local.get 0 i32.const 1 i32.const 1 select drop))'
    ].each { |wat| assert_raise(Wardite::LoadError, E::TranslationError) { load_wat(wat) } }
    # Out-of-range type indices are checked by the loader, not wasm-tools.
    bytes = compile_efflorescence_wat('(module (tag) (func throw 0))')
    invalid_tag_type = bytes.sub("\x0d\x03\x01\x00\x00".b, "\x0d\x03\x01\x00\x01".b)
    assert_not_equal bytes, invalid_tag_type
    assert_raise(Wardite::LoadError) { Wardite::BinaryLoader.load_from_buffer(StringIO.new(invalid_tag_type), enable_wasi: false, engine: :efflorescence) }
  end

  test 'malformed blocktypes catch headers and truncated LEB128 fail during decoding' do
    [
      [0x02, 0xff, 0x7f], # value type cannot use an s33 index encoding
      [0x02, 0xc0, 0x7f], # void must also use one byte
      [0x02, 0x80], # truncated signed LEB
      [0x02, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00], # too long s33
      [0x02, 0xff, 0xff, 0xff, 0xff, 0x0f], # outside s33
      [0x02, 0xff, 0x7e], # invalid negative blocktype
      [0x1f, 0x40, 0x01, 0x04], # invalid catch kind
      [0x1f, 0x40, 0x01, 0x00], # missing tag and label
      [0x1f, 0x40, 0x01, 0x02, 0x80], # truncated catch_all label
      [0x1f, 0x40, 0x00], # missing end
      [0x08, 0x80], # truncated tag index
      [0x08, 0xff, 0xff, 0xff, 0xff, 0x10] # exceeds u32
    ].each do |bytes|
      assert_raise(Wardite::LoadError) { Wardite::BinaryLoader.code_body(StringIO.new(bytes.pack('C*'))) }
    end
    # A block type index is s33, so even a multi-byte nonnegative index parses.
    block = Wardite::BinaryLoader.read_blocktype(StringIO.new([0xc0, 0x00].pack('C*')))
    assert_equal 64, block.type_index
    assert_raise(Wardite::LoadError) do
      load_wat('(module (func block (type 8) end))')
    end
  end

  test "shared decode specs match the legacy normal and extended opcode resolver" do
    op = Wardite::Op
    cases = op::NAMESPACES.each_with_index.map do |namespace, opcode|
      [opcode, [], namespace, op::SYMS.fetch(opcode)]
    end
    cases += op::FC_SYMS.each_with_index.map do |code, prefix|
      [0xfc, [prefix], op::FC_OPERANDS[prefix] || :default, code]
    end
    cases.each do |opcode, immediate, namespace, code|
      input = immediate.pack('C*')
      expected = [namespace, code, LegacyWasmDecode.operand_of(code)]
      resolved = Wardite::BinaryLoader.resolve_code(opcode.chr(Encoding::BINARY), StringIO.new(input))
      assert_equal expected, resolved
      resolved.last << :u8
      assert_equal expected.last, op.operand_of(code)
      op.operand_of(code) << :u8
      assert_equal expected, Wardite::BinaryLoader.resolve_code(opcode.chr(Encoding::BINARY), StringIO.new(input))
    end

    assert_raise_message(/unsupported code: 255/) { Wardite::BinaryLoader.resolve_code("\xff".b, StringIO.new) }
    assert_equal [:default, nil, []], Wardite::BinaryLoader.resolve_code("\xfc".b, StringIO.new("\xff\x01".b))
    assert_raise_message(/truncated unsigned LEB128/) { Wardite::BinaryLoader.resolve_code("\xfc".b, StringIO.new) }
  end

  test "body decoding preserves byte zero, structured targets, NaN bits, memargs and catch operands" do
    bytes = [
      0x00, 0x04, 0x7f, 0x41, 0, 0x05, 0x41, 1, 0x0b, # unreachable; if (result i32); else; end
      0x43, 0x23, 0x01, 0x80, 0x7f,                       # f32 NaN payload
      0x44, 0x23, 0x01, 0, 0, 0, 0, 0xf0, 0xff,            # f64 NaN payload
      0x28, 0, 7,                                         # i32.load align=0 offset=7
      0xfc, 0x8b, 0, 0,                                   # memory.fill with padded subopcode
      0x1f, 0x40, 2, 0, 0, 3, 3, 4, 0x0b, 0x0b            # try_table catch + catch_all_ref
    ].pack('C*')
    expected = [
      [:default, :unreachable, [], nil, nil],
      [:default, :if, [[-1, [0x7f], [], [:i32]]], 3, 5],
      [:i32, :i32_const, [0], nil, nil],
      [:default, :else, [], nil, nil],
      [:i32, :i32_const, [1], nil, nil],
      [:default, :end, [], nil, nil],
      [:f32, :f32_const, [0x7f800123], nil, nil],
      [:f64, :f64_const, [0xfff0000000000123 - (1 << 64)], nil, nil],
      [:i32, :i32_load, [0, 7], nil, nil],
      [:default, :memory_fill, [0], nil, nil],
      [:default, :try_table, [[-1, nil, [], []], [0, 0, 3, 3, -1, 4]], nil, 11],
      [:default, :end, [], nil, nil],
      [:default, :end, [], nil, nil]
    ]
    Tempfile.create('wasm-body', binmode: true) do |file|
      file.write(bytes)
      file.rewind
      [StringIO.new(bytes), file].each do |input|
        decoded = Wardite::BinaryLoader.code_body(input).map do |namespace, code, operands, else_pc, end_pc|
          values = operands.map do |operand|
            case operand
            when Wardite::Block then [operand.type_index, operand.block_types, operand.parameter_types, operand.result_types]
            when Wardite::FloatImmediate then operand.bits
            when Wardite::OperandVector then operand.entries
            else operand
            end
          end
          [namespace, code, values, else_pc, end_pc]
        end
        assert_equal expected, decoded
        assert_equal [], Wardite::BinaryLoader.code_body(input)
      end
    end
  end
end
