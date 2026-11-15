# frozen_string_literal: true

require "test_helper"
require "wardite/efflorescence/mir_cache"

require_relative "support/legacy_mir_reads"

class EfflorescenceRegisterValidationTest < Test::Unit::TestCase
  E = Wardite::Efflorescence
  OP = E::Opcode

  test "read positions and cache register masks agree with the previous operand roles" do
    OP::NAMES.each_index do |opcode|
      instruction = E::Instruction.new([opcode, 7, 8, 9, 10])
      expected = LegacyMIRReads.positions(instruction)
      assert_equal expected.size, OP.read_count(instruction)
      assert_equal expected, expected.each_index.map { |ordinal| OP.read_position(instruction, ordinal) }
      copy = OP.read_positions(instruction)
      assert_equal expected, copy
      copy << 99
      assert_equal expected, OP.read_positions(instruction)
      assert_raise(IndexError) { OP.read_position(instruction, expected.size) }
      assert_raise(IndexError) { OP.read_position(instruction, -1) }

      mask = 0
      unless [OP::CALL, OP::RETURN].include?(opcode)
        positions = LegacyMIRReads.positions(E::Instruction.new([opcode, 0, 0, 0]))
        positions << 1 if OP.destination(instruction) >= 0 && !OP.dynamic_call?(opcode)
        positions.each { |position| mask |= 1 << (position - 1) }
      end
      assert_equal mask, E::MIRCache::Decoder::REGISTER_MASKS.fetch(opcode)
    end

    [-1, OP::NAMES.size].each do |opcode|
      assert_raise(E::UnsupportedFeature) { OP.read_count(E::Instruction.new([opcode])) }
    end
  end

  test "read access includes variable and side operands in order with duplicates" do
    function = E::Function.new(0, [], [], 0)
    function.throw_sites << E::ThrowSite.new(0, [3, 3, 4])
    function.memory_sites << E::MemorySite.new([5, 6, 5])
    function.dynamic_sites << E::DynamicCallSite.new(0, [8, 4, 4], [:i32, :i32, :i32], [])
    cases = [
      [[OP::CALL, -1, 9], []],
      [[OP::CALL, -1, 9, 2, 2, 4], [2, 2, 4]],
      [[OP::RETURN, -1], []],
      [[OP::RETURN, 0], [0]],
      [[OP::THROW, 0], [3, 3, 4]],
      [[OP::MEMORY_INIT, 0], [5, 6, 5]],
      [[OP::MEMORY_FILL, 0], [5, 6, 5]],
      [[OP::MEMORY_COPY, 0], [5, 6, 5]],
      [[OP::CALL_HOST, -1, 0, 0], [8, 4, 4]],
      [[OP::CALL_INDIRECT, -1, 0, 8], [8, 8, 4, 4]]
    ]
    cases.each do |operands, expected|
      instruction = E::Instruction.new(operands)
      assert_equal expected.size, function.read_count(instruction)
      assert_equal expected, expected.each_index.map { |ordinal| function.read_at(instruction, ordinal) }
      assert_equal expected, function.reads(instruction)
      function.reads(instruction).clear
      assert_equal expected, function.reads(instruction)
      assert_raise(IndexError) { function.read_at(instruction, expected.size) }
      assert_raise(IndexError) { function.read_at(instruction, -1) }
    end
  end
end
