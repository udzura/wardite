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
end
