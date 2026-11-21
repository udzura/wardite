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
end
