# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    module FloatArithmetic
      F32_SIGN = 0x80000000
      F32_INFINITY = 0x7f800000
      F64_INFINITY = 0x7ff0000000000000
      F32_NAN = 0x7fc00000
      F64_NAN = 0x7ff8000000000000

      # @rbs opcode: Integer
      # @rbs left: Integer
      # @rbs right: Integer
      # @rbs return: Integer
      def self.calculate(opcode, left, right)
        type = opcode < Opcode::F64_EQ ? :f32 : :f64
        op = type == :f32 ? opcode : opcode - (Opcode::F64_EQ - Opcode::F32_EQ)
        sign = type == :f32 ? F32_SIGN : I64Arithmetic::MIN
        magnitude = left & ~sign
        infinity = type == :f32 ? F32_INFINITY : F64_INFINITY
        nan = type == :f32 ? F32_NAN : F64_NAN
        case op
        when Opcode::F32_ABS then return magnitude
        when Opcode::F32_NEG then return left ^ sign
        when Opcode::F32_COPYSIGN then return magnitude | (right & sign)
        end

        other_magnitude = right & ~sign
        if magnitude > infinity || other_magnitude > infinity
          return op == Opcode::F32_NE ? 1 : 0 if op <= Opcode::F32_GE
          return nan
        end

        x = FloatBits.to_float(type, left)
        if op >= Opcode::F32_CEIL && op <= Opcode::F32_NEAREST
          # Values from 2**fraction_width onward are already integral.
          limit = type == :f32 ? 0x4b000000 : 0x4330000000000000
          return left if magnitude == 0 || magnitude >= limit
          rounded = integral(op, x)
          return left & sign if rounded == 0
          return FloatBits.from_float(type, rounded.to_f)
        end

        if op == Opcode::F32_SQRT
          return nan if (left & sign) != 0 && magnitude != 0
          return FloatBits.from_float(type, sqrt(x))
        end

        y = FloatBits.to_float(type, right)
        case op
        when Opcode::F32_EQ then return x == y ? 1 : 0
        when Opcode::F32_NE then return x != y ? 1 : 0
        when Opcode::F32_LT then return x < y ? 1 : 0
        when Opcode::F32_GT then return x > y ? 1 : 0
        when Opcode::F32_LE then return x <= y ? 1 : 0
        when Opcode::F32_GE then return x >= y ? 1 : 0
        when Opcode::F32_MIN
          return (left | right) if magnitude == 0 && other_magnitude == 0
          return x < y ? left : right
        when Opcode::F32_MAX
          return (left & right) if magnitude == 0 && other_magnitude == 0
          return x > y ? left : right
        end

        result = case op
                 when Opcode::F32_ADD then x + y
                 when Opcode::F32_SUB then x - y
                 when Opcode::F32_MUL then x * y
                 when Opcode::F32_DIV then divide(x, y)
                 else raise EvalError, "invalid MIR float opcode"
                 end
        result.nan? ? nan : FloatBits.from_float(type, result)
      end

      # @rbs op: Integer
      # @rbs value: Float
      # @rbs return: Integer
      def self.integral(op, value)
        case op
        when Opcode::F32_CEIL then value.ceil
        when Opcode::F32_FLOOR then value.floor
        when Opcode::F32_TRUNC then value.to_i
        else
          # Use the magnitude so subtraction near 0.5 is exact.
          magnitude = value.abs
          lower = magnitude.floor
          fraction = magnitude - lower.to_f
          rounded = fraction > 0.5 || (fraction == 0.5 && lower.odd?) ? lower + 1 : lower
          value < 0.0 ? -rounded : rounded
        end
      end

      # A normalized quotient of binary32 inputs is A/B scaled by a power of
      # two. B < 2**24. Its distance from a binary32 midpoint, unless equal,
      # exceeds 2**-48 in the quotient's binade scaled to [1, 2).
      # @rbs left: Float
      # @rbs right: Float
      # @rbs return: Float
      def self.divide(left, right)
        left / right
      end

      # Squaring a binary32 midpoint gives a dyadic with at most 48 fractional
      # bits in that binade's scale. A distinct binary32 radicand differs by at
      # least 2**-48, so its square root differs by more than 2**-50.
      # @rbs value: Float
      # @rbs return: Float
      def self.sqrt(value)
        return value if value == 0.0
        value < 0.0 ? Float::NAN : Math.sqrt(value)
      end
    end
  end
end
