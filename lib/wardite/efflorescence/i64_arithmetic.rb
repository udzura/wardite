# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    module I64Arithmetic
      MASK = 0xffffffff
      MIN = -9223372036854775807 - 1 #: Integer

      # @rbs value: Integer
      # @rbs return: Integer
      def self.low(value)
        value & MASK
      end

      # @rbs value: Integer
      # @rbs return: Integer
      def self.high(value)
        (value >> 32) & MASK
      end

      # @rbs low: Integer
      # @rbs high: Integer
      # @rbs return: Integer
      def self.join(low, high)
        low | ((high & 0x7fffffff) << 32) | ((high >> 31) * MIN)
      end

      # @rbs value: Integer
      # @rbs return: Integer
      def self.normalize(value)
        join(low(value), high(value))
      end

      # Sign extension for an integer field of at most 32 bits.
      # @rbs value: Integer
      # @rbs width: Integer
      # @rbs return: Integer
      def self.extend(value, width)
        limit = 1 << width
        field = value & (limit - 1)
        field >= (limit >> 1) ? field - limit : field
      end

      # @rbs left: Integer
      # @rbs right: Integer
      # @rbs return: bool
      def self.unsigned_less?(left, right)
        a, b = high(left), high(right)
        a == b ? low(left) < low(right) : a < b
      end

      # @rbs value: Integer
      # @rbs count: Integer
      # @rbs return: Integer
      def self.shift_left(value, count)
        return value if count == 0

        lo = low(value)
        if count < 32
          hi = ((high(value) << count) | (lo >> (32 - count))) & MASK
          join((lo << count) & MASK, hi)
        elsif count == 32
          join(0, lo)
        else
          join(0, (lo << (count - 32)) & MASK)
        end
      end

      # @rbs value: Integer
      # @rbs count: Integer
      # @rbs signed: bool
      # @rbs return: Integer
      def self.shift_right(value, count, signed)
        return value if count == 0

        hi = signed ? value >> 32 : high(value)
        if count < 32
          # Mask hi before shifting left so the intermediate fits in 63 bits.
          lo = (low(value) >> count) | ((high(value) << (32 - count)) & MASK)
          join(lo, (hi >> count) & MASK)
        else
          lo = count == 32 ? hi : hi >> (count - 32)
          join(lo & MASK, hi < 0 ? MASK : 0)
        end
      end

      # @rbs value: Integer
      # @rbs return: Integer
      def self.clz32(value)
        count = 32
        while value != 0
          count -= 1
          value >>= 1
        end
        count
      end

      # @rbs value: Integer
      # @rbs return: Integer
      def self.ctz32(value)
        return 32 if value == 0

        count = 0
        while (value & 1) == 0
          count += 1
          value >>= 1
        end
        count
      end

      # @rbs value: Integer
      # @rbs return: Integer
      def self.popcnt32(value)
        count = 0
        while value != 0
          value &= value - 1
          count += 1
        end
        count
      end

      # @rbs left: Integer
      # @rbs right: Integer
      # @rbs return: Integer
      def self.add_i64(left, right)
        sum = low(left) + low(right)
        join(sum & MASK, (high(left) + high(right) + (sum >> 32)) & MASK)
      end

      # @rbs left: Integer
      # @rbs right: Integer
      # @rbs return: Integer
      def self.subtract_i64(left, right)
        difference = low(left) - low(right)
        join(difference & MASK, (high(left) - high(right) + (difference >> 32)) & MASK)
      end

      # Only the four least significant base-2**16 digits contribute.
      # @rbs left: Integer
      # @rbs right: Integer
      # @rbs return: Integer
      def self.multiply_i64(left, right)
        a0, a1, a2, a3 = left & 0xffff, (left >> 16) & 0xffff, (left >> 32) & 0xffff, (left >> 48) & 0xffff
        b0, b1, b2, b3 = right & 0xffff, (right >> 16) & 0xffff, (right >> 32) & 0xffff, (right >> 48) & 0xffff
        w0 = a0 * b0
        w1 = (w0 >> 16) + a0 * b1 + a1 * b0
        w2 = (w1 >> 16) + a0 * b2 + a1 * b1 + a2 * b0
        w3 = (w2 >> 16) + a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0
        join((w0 & 0xffff) | ((w1 & 0xffff) << 16), (w2 & 0xffff) | ((w3 & 0xffff) << 16))
      end

      # The sign bit remains part of the unsigned magnitude, including MIN.
      # @rbs opcode: Integer
      # @rbs left: Integer
      # @rbs right: Integer
      # @rbs return: Integer
      def self.divide(opcode, left, right)
        raise Wardite::EvalError, "integer divide by zero" if right == 0
        if opcode == Opcode::I64_DIV_S && left == MIN && right == -1
          raise Wardite::IntegerOverflow, "integer division overflow"
        end

        signed = opcode == Opcode::I64_DIV_S || opcode == Opcode::I64_REM_S
        remainder = opcode == Opcode::I64_REM_S || opcode == Opcode::I64_REM_U
        left_negative = signed && left < 0
        right_negative = signed && right < 0
        dividend = left_negative ? subtract_i64(0, left) : left
        divisor = right_negative ? subtract_i64(0, right) : right
        result = unsigned_divide(dividend, divisor, remainder)
        negative = remainder ? left_negative : left_negative != right_negative
        negative ? subtract_i64(0, result) : result
      end

      # Shift in one dividend bit per step. Preserve the extra remainder bit
      # until comparison and subtraction have consumed it.
      # @rbs dividend: Integer
      # @rbs divisor: Integer
      # @rbs remainder: bool
      # @rbs return: Integer
      def self.unsigned_divide(dividend, divisor, remainder)
        nlo, nhi = low(dividend), high(dividend)
        dlo, dhi = low(divisor), high(divisor)
        rlo, rhi = 0, 0
        qlo, qhi = 0, 0
        bit = 63
        while bit >= 0
          incoming = bit >= 32 ? (nhi >> (bit - 32)) & 1 : (nlo >> bit) & 1
          carry = rhi >> 31
          rhi = ((rhi << 1) | (rlo >> 31)) & MASK
          rlo = ((rlo << 1) | incoming) & MASK
          if carry != 0 || rhi > dhi || (rhi == dhi && rlo >= dlo)
            difference = rlo - dlo
            rlo = difference & MASK
            rhi = (rhi - dhi + (difference >> 32)) & MASK
            if bit >= 32
              qhi |= 1 << (bit - 32)
            else
              qlo |= 1 << bit
            end
          end
          bit -= 1
        end
        remainder ? join(rlo, rhi) : join(qlo, qhi)
      end

      # @rbs opcode: Integer
      # @rbs left: Integer
      # @rbs right: Integer
      # @rbs return: Integer
      def self.calculate(opcode, left, right)
        case opcode
        when Opcode::I64_ADD then add_i64(left, right)
        when Opcode::I64_SUB then subtract_i64(left, right)
        when Opcode::I64_MUL then multiply_i64(left, right)
        when Opcode::I64_DIV_S, Opcode::I64_DIV_U, Opcode::I64_REM_S, Opcode::I64_REM_U
          divide(opcode, left, right)
        when Opcode::I64_EQZ then left == 0 ? 1 : 0
        when Opcode::I64_EQ then left == right ? 1 : 0
        when Opcode::I64_NE then left != right ? 1 : 0
        when Opcode::I64_LTS then left < right ? 1 : 0
        when Opcode::I64_LTU then unsigned_less?(left, right) ? 1 : 0
        when Opcode::I64_GTS then left > right ? 1 : 0
        when Opcode::I64_GTU then unsigned_less?(right, left) ? 1 : 0
        when Opcode::I64_LES then left <= right ? 1 : 0
        when Opcode::I64_LEU then unsigned_less?(right, left) ? 0 : 1
        when Opcode::I64_GES then left >= right ? 1 : 0
        when Opcode::I64_GEU then unsigned_less?(left, right) ? 0 : 1
        when Opcode::I64_AND then left & right
        when Opcode::I64_OR then left | right
        when Opcode::I64_XOR then left ^ right
        when Opcode::I64_SHL then shift_left(left, right & 63)
        when Opcode::I64_SHR_S then shift_right(left, right & 63, true)
        when Opcode::I64_SHR_U then shift_right(left, right & 63, false)
        when Opcode::I64_ROTL, Opcode::I64_ROTR
          count = right & 63
          count = (64 - count) & 63 if opcode == Opcode::I64_ROTR
          shift_left(left, count) | shift_right(left, (64 - count) & 63, false)
        when Opcode::I64_CLZ
          hi = high(left)
          hi == 0 ? 32 + clz32(low(left)) : clz32(hi)
        when Opcode::I64_CTZ
          lo = low(left)
          lo == 0 ? 32 + ctz32(high(left)) : ctz32(lo)
        when Opcode::I64_POPCNT then popcnt32(low(left)) + popcnt32(high(left))
        when Opcode::I32_WRAP_I64 then low(left)
        when Opcode::I64_EXTEND_I32_U then left
        when Opcode::I64_EXTEND_I32_S, Opcode::I64_EXTEND32_S then extend(left, 32)
        when Opcode::I64_EXTEND16_S then extend(left, 16)
        when Opcode::I64_EXTEND8_S then extend(left, 8)
        else
          raise Wardite::EvalError, "invalid i64 opcode"
        end
      end
    end
  end
end
