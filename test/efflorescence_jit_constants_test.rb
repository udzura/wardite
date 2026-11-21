# frozen_string_literal: true

require "test_helper"
require "wardite/efflorescence/spinel_jit/aarch64"

class EfflorescenceJITConstantsTest < Test::Unit::TestCase
  include Wardite::Efflorescence

  # The same MIR constant is in w14 (last resident register) or r15
  # (outside the mapping). Use the emitted arithmetic operands to distinguish
  # reuse from the scratch path even when both produce the same result.
  test "immediate arithmetic reuses only initialized constant registers" do
    [14, 15].each do |slot|
      fn = Function.new(0, [:i32, :i32], [:i32], slot - 2)
      bits = 0x12345678
      fn.allocate_constant(bits)
      fn.allocate_constant(0) # outside the mapping in both cases
      fn.install_code([
        Opcode::I32_MUL_IMM, 0, 0, bits,
        Opcode::I32_ADD_IMM, 0, 0, bits,
        Opcode::I32_SUB_IMM, 0, 0, bits,
        Opcode::I32_MUL_IMM, 0, 0, 0,
        Opcode::RETURN, 0, 0, 0
      ], [])

      words = SpinelJIT::AArch64.new.compile(fn).unpack("V*")
      # MUL, ADD and SUB with register operands encode the right input in Rm
      # (bits 20:16). Zero must use scratch even though all locals start at 0.
      arithmetic = words.select { |word| [0x1b, 0x0b, 0x4b].include?(word >> 24) }
      assert_equal [slot, slot, slot, 15], arithmetic.map { |word| (word >> 16) & 31 }
      assert_include words, 0x5280000f, "the unmapped zero must be loaded with movz w15, #0"
    end
  end
end
