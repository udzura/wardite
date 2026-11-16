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

  test "plain blocks agree with instruction flow on joins, loops and dead code" do
    cases = {
      linear: [[[OP::COPY, 65, 0], [OP::RETURN, 65]], nil],
      diamond: [[[OP::BR_IF, 0, 3], [OP::COPY, 65, 0], [OP::BR, 4],
                 [OP::COPY, 65, 66], [OP::RETURN, 65]], nil],
      loop: [[[OP::COPY, 65, 0], [OP::BR_IF, 0, 4], [OP::I32_ADD_IMM, 65, 65, 1],
              [OP::BR, 1], [OP::RETURN, 65]], nil],
      self_loop_at_end: [[[OP::BR_IF, 0, 0]], nil],
      coincident_edges: [[[OP::BR_IF, 0, 1], [OP::RETURN, 0]], nil],
      unreachable_fallthrough: [[[OP::RETURN, 0], [OP::COPY, 66, 65]], nil],
      unreachable_bad_target: [[[OP::RETURN, 0], [OP::BR, -1]], /invalid MIR branch target -1/],
      bad_target: [[[OP::BR, 1]], /invalid MIR branch target 1/],
      reachable_fallthrough: [[[OP::COPY, 65, 0]], /MIR falls through without RETURN/],
      constant_destination: [[[OP::COPY, 66, 0], [OP::RETURN, 66]], /MIR PC 0: invalid register destination r66/],
      missing_definition: [[[OP::BR_IF, 0, 2], [OP::COPY, 65, 0], [OP::RETURN, 65]], /MIR PC 2: r65 read before definition/],
      unreachable_bad_register: [[[OP::RETURN, 0], [OP::RETURN, 67]], /invalid MIR register type\/index r67/],
      call_reads_before_writing: [[[OP::CALL, 65, 1, 65], [OP::RETURN, 65]], /MIR PC 0: r65 read before definition/]
    }

    cases.each do |name, (code, message)|
      function = E::Function.new(0, [:i32], [:i32], 64)
      function.allocate_register(0)
      function.allocate_constant(42)
      function.replace_instructions(code.map { |operands| E::Instruction.new(operands) })
      [false, true].each do |uses_eh|
        function.uses_eh = uses_eh
        assert_equal(uses_eh && name != :unreachable_bad_register ? 1 : 0, count_flow_graphs {
          if message
            assert_raise_message(message) { E::RegisterValidation.new.validate(function) }
          else
            assert_nothing_raised(name.to_s) { E::RegisterValidation.new.validate(function) }
          end
        }, name.to_s)
      end
    end
  end

  test "an EH instruction with an unset feature flag still checks handler state" do
    function = E::Function.new(0, [], [], 0)
    function.replace_instructions([E::Instruction.new([OP::EH_TRIM, 1]), E::Instruction.new([OP::RETURN, -1])])
    assert_false function.uses_eh
    assert_equal 1, count_flow_graphs {
      assert_raise_message(/invalid handler trim/) { E::RegisterValidation.new.validate(function) }
    }
  end

  test "EH flow rejects incongruent handler stacks at a normal join" do
    function = E::Function.new(0, [:i32], [], 0)
    function.handlers << E::HandlerDescriptor.new([])
    code = [[OP::EH_ENTER, 0], [OP::BR_IF, 0, 3], [OP::EH_TRIM, 0], [OP::RETURN, -1]]
    function.replace_instructions(code.map { |operands| E::Instruction.new(operands) })
    assert_raise_message("inconsistent handler stack at MIR PC 3") { E::RegisterValidation.new.validate(function) }
  end

  private

  def count_flow_graphs
    builds = 0
    trace = TracePoint.new(:call) do |event|
      builds += 1 if event.defined_class == E::FlowGraph && event.method_id == :initialize
    end
    trace.enable { yield }
    builds
  end
end
