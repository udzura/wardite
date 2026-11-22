# frozen_string_literal: true

require "test_helper"
require "wardite"

class EfflorescenceLocalCSETest < Test::Unit::TestCase
  E = Wardite::Efflorescence
  include E::Opcode

  def optimize(words)
    fn = E::Function.new(0, [:i32, :i32], [:i32], 8)
    fn.replace_instructions(words.map { |operands| E::Instruction.new(operands.dup) })
    yield fn if block_given?
    E::Passes::LocalCSE.new.run(fn)
    fn.instructions.map(&:operands)
  end

  test "reuse the value held by a copy after the producer is overwritten" do
    assert_equal [[I32_ADD, 2, 0, 1], [COPY, 3, 2], [COPY, 2, 0], [RETURN, 3]],
      optimize([[I32_ADD, 2, 0, 1], [COPY, 3, 2], [COPY, 2, 0], [I32_ADD, 4, 1, 0], [RETURN, 4]])
  end

  test "a changed input, an overwritten last holder and different immediates miss" do
    words = [[I32_ADD_IMM, 2, 0, 7], [COPY, 2, 1], [I32_ADD_IMM, 3, 0, 7],
             [I32_ADD_IMM, 4, 0, 9], [COPY, 0, 1], [I32_ADD_IMM, 5, 0, 7], [RETURN, 5]]
    assert_equal words, optimize(words)
  end

  test "keep the duplicate destination live for a side table and a successor block" do
    words = [[I32_AND, 2, 0, 1], [I32_AND, 3, 0, 1], [MEMORY_FILL, 0],
             [BR_IF, 0, 5], [COPY, 2, 1], [RETURN, 3]]
    actual = optimize(words) { |fn| fn.memory_sites << E::MemorySite.new([0, 3, 1]) }
    assert_equal [COPY, 3, 2], actual[1]
    assert_equal words.drop(2), actual.drop(2)
    # Even a destination used only by the side table needs its COPY.
    assert_equal [COPY, 3, 2], optimize(words.take(3) + [[RETURN, 2]]) { |fn|
      fn.memory_sites << E::MemorySite.new([0, 3, 1])
    }[1]
  end

  test "catch targets start a new block even when only the exceptional edge enters" do
    words = [[I32_AND, 2, 0, 1], [I32_AND, 3, 0, 1], [RETURN, 3]]
    actual = optimize(words) do |fn|
      fn.handlers << E::HandlerDescriptor.new([E::CatchTarget.new(0, [], -1, 1, 0)])
    end
    assert_equal words, actual
  end

  test "keep two trapping reads, divisions, global reads and floating point operations" do
    [[I32_LOAD, 2, 0, 4], [I32_DIV_U, 2, 0, 1], [GLOBAL_GET, 2, 0], [F32_ADD, 2, 0, 1]].each do |first|
      second = first.dup
      second[1] = 3
      words = [first, second, [RETURN, 3]]
      assert_equal words, optimize(words)
    end
  end
end
