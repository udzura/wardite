# frozen_string_literal: true

module EfflorescenceInvalidCases
  def malformed_i32_constant
    # A six-byte representation of zero is outside s32, even in dead code.
    preamble = "\0asm\1\0\0\0".b
    preamble + [
      1, 4, 1, 0x60, 0, 0,
      3, 2, 1, 0,
      10, 13, 1, 11, 0, 0, 0x41, 0x80, 0x80, 0x80, 0x80, 0x80, 0, 0x1a, 0x0b
    ].pack("C*")
  end

  def malformed_numeric_fixtures
    [
      [malformed_i32_constant, "signed LEB128 exceeds"],
      [compile_efflorescence_wat("(module (global f32 (f64.const 1)))"), "global initializer type mismatch"]
    ]
  end
end
