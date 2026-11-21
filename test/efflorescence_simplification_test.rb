# frozen_string_literal: true

require "test_helper"
require "wardite"

class EfflorescenceSimplificationTest < Test::Unit::TestCase
  E = Wardite::Efflorescence
  include E::Opcode

  def body(words, params: 1, locals: 0, temps: 5)
    fn = E::Function.new(0, Array.new(params, :i32), [:i32], locals)
    temps.times { fn.allocate_register(0) }
    fn.replace_instructions(words.map { |ops| E::Instruction.new(ops.dup) })
    fn
  end

  test "constant folding keeps Wasm widths and signed comparisons" do
    pass = E::Passes::ConstantFolding.new
    assert_equal 1, pass.calculate(I32_MUL, 0xffffffff, 0xffffffff)
    assert_equal 2, pass.calculate(I32_SHL_IMM, 1, 33)
    assert_equal 0xffffffff, pass.calculate(I32_SHR_S, 0x80000000, 63)
    assert_equal 1, pass.calculate(I32_LTS, 0xffffffff, 0)
    assert_equal 0, pass.calculate(I32_LTU, 0xffffffff, 0)
    assert_equal E::I64Arithmetic::MIN, pass.calculate(I64_ADD, E::I64Arithmetic::MAX, 1)
    assert_equal 1, pass.calculate(I64_SHR_U, E::I64Arithmetic::MIN, 127)
  end

  test "thread jumps and preserve self loops and catch roots" do
    fn = body([[BR, 2], [TRAP], [BR, 4], [RETURN, 0], [BR, 4]])
    clause = E::CatchTarget.new(0, [], -1, 3, 0)
    fn.handlers << E::HandlerDescriptor.new([clause])
    E::Passes::ControlFlow.new.run(fn)
    assert_equal [[BR, 2], [RETURN, 0], [BR, 2]], fn.instructions.map(&:operands)
    assert_equal 1, clause.target_pc
  end

  test "dead definitions cascade across a backward edge but side-table uses remain" do
    fn = body([[BR, 4], [I32_MUL, 2, 1, 0], [MEMORY_FILL, 0], [RETURN, 0],
      [I32_ADD, 1, 0, 0], [I32_SUB, 3, 0, 0], [BR, 1]])
    fn.memory_sites << E::MemorySite.new([0, 3, 0])
    E::Passes::DeadCode.new.run(fn)
    assert_equal [[BR, 3], [MEMORY_FILL, 0], [RETURN, 0], [I32_SUB, 3, 0, 0], [BR, 1]],
      fn.instructions.map(&:operands)
  end

  test "LICM hoists an invariant once and leaves loop-carried inputs in place" do
    fn = body([[BR_IF_ZERO, 0, 5], [I32_AND, 2, 1, 1], [I32_SUB_IMM, 0, 0, 1],
      [I32_XOR, 3, 2, 0], [BR, 0], [RETURN, 1]], params: 2)
    E::Passes::LoopInvariants.new.run(fn)
    assert_equal [[I32_AND, 2, 1, 1], [BR_IF_ZERO, 0, 5], [I32_SUB_IMM, 0, 0, 1],
      [I32_XOR, 3, 2, 0], [BR, 1], [RETURN, 1]], fn.instructions.map(&:operands)
  end

  test "LICM skips side entrances and destinations observed after zero trips" do
    [
      [[BR_IF, 0, 3], [BR_IF_ZERO, 0, 6], [COPY, 3, 1], [I32_AND, 2, 1, 1], [COPY, 3, 2], [BR, 1], [RETURN, 0]],
      [[BR_IF_ZERO, 0, 4], [I32_AND, 2, 1, 1], [I32_SUB_IMM, 0, 0, 1], [BR, 0], [RETURN, 2]]
    ].each_with_index do |words, index|
      fn = body(words, params: 2, locals: index)
      E::Passes::LoopInvariants.new.run(fn)
      assert_equal words, fn.instructions.map(&:operands)
    end
  end
end
