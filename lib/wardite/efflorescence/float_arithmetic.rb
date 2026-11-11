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

      # @rbs opcode: Integer
      # @rbs bits: Integer
      # @rbs return: Integer
      def self.convert(opcode, bits)
        signature = Opcode::FLOAT_ALU_TYPES.fetch(opcode)
        target, source = signature.fetch(0), signature.fetch(1)
        case opcode
        when Opcode::F32_DEMOTE_F64, Opcode::F64_PROMOTE_F32
          mask = source == :f32 ? F32_SIGN : I64Arithmetic::MIN
          infinity = source == :f32 ? F32_INFINITY : F64_INFINITY
          return target == :f32 ? F32_NAN : F64_NAN if (bits & ~mask) > infinity

          FloatBits.from_float(target, FloatBits.to_float(source, bits))
        else
          if opcode < Opcode::F32_CONVERT_I32_S
            signed = (opcode - Opcode::I32_TRUNC_F32_S).even?
            saturating = opcode >= Opcode::I32_TRUNC_SAT_F32_S
            truncate(target, source, bits, signed, saturating)
          else
            signed = (opcode - Opcode::F32_CONVERT_I32_S).even?
            integer = source == :i32 && signed ? I64Arithmetic.extend(bits, 32) : bits
            integer_to_float(target, integer, signed)
          end
        end
      end

      # Round the unsigned magnitude directly to the target significand.
      # @rbs target: Symbol
      # @rbs value: Integer
      # @rbs signed: bool
      # @rbs return: Integer
      def self.integer_to_float(target, value, signed)
        return 0 if value == 0

        negative = signed && value < 0
        magnitude = negative ? I64Arithmetic.subtract_i64(0, value) : value
        high = I64Arithmetic.high(magnitude)
        exponent = high == 0 ? 31 - I64Arithmetic.clz32(magnitude) : 63 - I64Arithmetic.clz32(high)
        fraction_width = target == :f32 ? 23 : 52
        bias = target == :f32 ? 127 : 1023
        shift = exponent - fraction_width
        if shift > 0
          significand = I64Arithmetic.shift_right(magnitude, shift, false)
          halfway = 1 << (shift - 1)
          remainder = magnitude & ((halfway << 1) - 1)
          significand += 1 if remainder > halfway || (remainder == halfway && significand.odd?)
          if significand == (2 << fraction_width)
            significand >>= 1
            exponent += 1
          end
        else
          significand = magnitude << -shift
        end
        bits = ((exponent + bias) << fraction_width) | (significand & ((1 << fraction_width) - 1))
        sign_bit = target == :f32 ? F32_SIGN : I64Arithmetic::MIN
        negative ? bits | sign_bit : bits
      end

      # Compare the truncated magnitude in integer space, including MIN and
      # the upper half of unsigned i64, which both have the carrier sign set.
      # @rbs target: Symbol
      # @rbs source: Symbol
      # @rbs bits: Integer
      # @rbs signed: bool
      # @rbs saturating: bool
      # @rbs return: Integer
      def self.truncate(target, source, bits, signed, saturating)
        fraction_width = source == :f32 ? 23 : 52
        bias = source == :f32 ? 127 : 1023
        negative = source == :f32 ? (bits & F32_SIGN) != 0 : bits < 0
        exponent = ((bits >> fraction_width) & (2 * bias + 1)) - bias
        fraction = bits & ((1 << fraction_width) - 1)
        if exponent == bias + 1 && fraction != 0
          raise EvalError, "invalid conversion to integer" unless saturating
          return 0
        end
        return 0 if exponent < 0

        width = target == :i32 ? 32 : 64
        if exponent < width && (signed || !negative)
          significand = fraction | (1 << fraction_width)
          shift = exponent - fraction_width
          magnitude = shift < 0 ? significand >> -shift : I64Arithmetic.shift_left(significand, shift)
          sign_bit = width == 32 ? F32_SIGN : I64Arithmetic::MIN
          if !signed || exponent < width - 1 || (negative && magnitude == sign_bit)
            result = negative ? I64Arithmetic.subtract_i64(0, magnitude) : magnitude
            return width == 32 ? I64Arithmetic.low(result) : result
          end
        end
        raise Wardite::IntegerOverflow, "integer overflow" unless saturating

        if negative
          signed ? (width == 32 ? F32_SIGN : I64Arithmetic::MIN) : 0
        elsif signed
          width == 32 ? 0x7fffffff : 0x7fffffffffffffff
        else
          width == 32 ? 0xffffffff : -1
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
