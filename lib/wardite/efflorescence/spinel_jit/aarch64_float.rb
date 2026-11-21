# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    class SpinelJIT
      class AArch64
        private

        # @rbs slot: Integer
        # @rbs return: bool
        def wide_slot?(slot)
          type = @types.fetch(slot)
          type == :i64 || type == :f64
        end

        # Round to nearest/even, keep subnormals, mask FP exceptions, and use
        # canonical arithmetic NaNs. Preserve the caller's environment on replay too.
        # @rbs return: void
        def save_float_environment
          @words << 0xd53b4410 # mrs x16, fpcr
          @words << 0xd53b4431 # mrs x17, fpsr
          @words << 0xa9bf47f0 # stp x16, x17, [sp, #-16]!
          @words << 0xd2a04010 # mov x16, #(1 << 25) (DN)
          @words << 0xd51b4410 # msr fpcr, x16
        end

        # @rbs return: void
        def restore_float_environment
          @words << 0xa8c147f0 # ldp x16, x17, [sp], #16
          @words << 0xd51b4410 # msr fpcr, x16
          @words << 0xd51b4431 # msr fpsr, x17
        end

        # MIR slots hold raw bits. Only v0 and v1 are used for FP arithmetic.
        # @rbs op: Integer
        # @rbs dest: Integer
        # @rbs left: Integer
        # @rbs c: Integer
        # @rbs return: bool
        def emit_float(op, dest, left, c)
          types = Opcode::FLOAT_ALU_TYPES.fetch(op)
          if op > Opcode::F64_COPYSIGN
            emit_float_conversion(op, dest, left, types)
            return true
          end

          double = types.fetch(1) == :f64
          kind = double ? op - (Opcode::F64_EQ - Opcode::F32_EQ) : op
          fp_size = double ? 0x00400000 : 0
          to_fp = double ? 0x9e670000 : 0x1e270000
          from_fp = double ? 0x9e660000 : 0x1e260000
          if types.size == 3
            return false unless c.between?(0, @types.size - 1)
            right = read_slot(c, RIGHT)
            if kind == Opcode::F32_COPYSIGN
              # Keep the right sign in scratch and insert the left magnitude.
              @words << (0xaa0003e0 | (right << 16) | SCRATCH)
              @words << ((double ? 0xb340f800 : 0x33007800) | (left << 5) | SCRATCH) # bfxil
              @words << (0xaa0003e0 | (SCRATCH << 16) | dest)
              return true
            end
            @words << (to_fp | (right << 5) | 1) # fmov s1/d1, right
          end
          @words << (to_fp | (left << 5)) # fmov s0/d0, left
          if kind <= Opcode::F32_GE
            # FCMP on an unordered pair sets C and V. LO/LS implement ordered LT/LE.
            condition = case kind
            when Opcode::F32_EQ then 0  # eq
            when Opcode::F32_NE then 1  # ne
            when Opcode::F32_LT then 3  # lo
            when Opcode::F32_GT then 12 # gt
            when Opcode::F32_LE then 9  # ls
            else 10                     # ge
            end
            @words << (0x1e212000 | fp_size) # fcmp s0, s1 or d0, d1
            @words << (0x1a9f07e0 | ((condition ^ 1) << 12) | dest) # cset
            return true
          end

          instruction = case kind
          when Opcode::F32_ABS then 0x1e20c000 # fabs
          when Opcode::F32_NEG then 0x1e214000 # fneg
          when Opcode::F32_CEIL then 0x1e24c000 # frintp
          when Opcode::F32_FLOOR then 0x1e254000 # frintm
          when Opcode::F32_TRUNC then 0x1e25c000 # frintz
          when Opcode::F32_NEAREST then 0x1e244000 # frintn
          when Opcode::F32_SQRT then 0x1e21c000
          when Opcode::F32_ADD then 0x1e212800
          when Opcode::F32_SUB then 0x1e213800
          when Opcode::F32_MUL then 0x1e210800
          when Opcode::F32_DIV then 0x1e211800
          when Opcode::F32_MIN then 0x1e215800 # fmin (propagates NaN)
          when Opcode::F32_MAX then 0x1e214800 # fmax
          else return false
          end
          @words << (instruction | fp_size)
          @words << (from_fp | dest)
          true
        end

        # @rbs op: Integer
        # @rbs dest: Integer
        # @rbs left: Integer
        # @rbs types: Array[Symbol]
        # @rbs return: void
        def emit_float_conversion(op, dest, left, types)
          result = types.fetch(0)
          source = types.fetch(1)
          if op >= Opcode::I32_REINTERPRET_F32
            base = result == :i64 || result == :f64 ? 0xaa0003e0 : 0x2a0003e0
            @words << (base | (left << 16) | dest)
          elsif op <= Opcode::I64_TRUNC_SAT_F64_U
            trapping = op < Opcode::I32_TRUNC_SAT_F32_S
            @words << ((source == :f64 ? 0x9e670000 : 0x1e270000) | (left << 5))
            # FCVTZ clamps invalid conversions and sets IOC (including NaN -> 0).
            # Clear sticky flags first so only this instruction can trigger replay.
            @words << 0xd51b443f if trapping # msr fpsr, xzr
            unsigned = (op - Opcode::I32_TRUNC_F32_S) & 1
            @words << (0x1e380000 | (result == :i64 ? 0x80000000 : 0) |
              (source == :f64 ? 0x00400000 : 0) | (unsigned << 16) | dest)
            if trapping
              @words << 0xd53b4430 # mrs x16, fpsr
              @words << 0x12000210 # and w16, w16, #1
              branch(0x35000000 | LEFT, BAILOUT)
            end
          else
            if op <= Opcode::F64_CONVERT_I64_U
              unsigned = (op - Opcode::F32_CONVERT_I32_S) & 1
              @words << (0x1e220000 | (source == :i64 ? 0x80000000 : 0) |
                (result == :f64 ? 0x00400000 : 0) | (unsigned << 16) | (left << 5)) # scvtf/ucvtf
            else
              @words << ((source == :f64 ? 0x9e670000 : 0x1e270000) | (left << 5))
              @words << (source == :f64 ? 0x1e624000 : 0x1e22c000) # fcvt
            end
            @words << ((result == :f64 ? 0x9e660000 : 0x1e260000) | dest)
          end
        end
      end
    end
  end
end
