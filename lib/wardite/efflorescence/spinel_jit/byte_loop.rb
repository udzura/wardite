# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    class SpinelJIT
      class AArch64
        # x0 points to 8-byte MIR slots, x1 to current linear memory, x2 is
        # its byte length. x3..x5 are scratch. Spill after each MIR write so
        # every exit has the exact register state at its continuation PC.
        # @rbs function: Function
        # @rbs head: Integer
        # @rbs latch: Integer
        # @rbs return: String?
        def compile_byte_loop(function, head, latch)
          code = function.bytecode
          width = Lowerer::WIDTH
          return unless head >= 0 && head % width == 0 && code.size <= 0x7fffffff
          types = function.register_types
          has_load = false
          pc = head
          while pc < latch
            op, a, b, c = code.fetch(pc), code.fetch(pc + 1), code.fetch(pc + 2), code.fetch(pc + 3)
            return unless a.between?(0, types.size - 1) && b.between?(0, types.size - 1)
            return unless types.fetch(a) == :i32 && types.fetch(b) == :i32
            load_loop_slot(4, b)
            case op
            when Opcode::I32_LOAD8_U
              return unless c.between?(0, 0xffffffff)
              # Extend the i32 base before adding the static Wasm offset.
              if c != 0
                load_constant(5, c, false)
                @words << 0x8b050084 # add x4, x4, x5
              end
              @words << 0xeb02009f # cmp x4, x2
              exit_unless(0x54000003, pc) # b.lo: address < length
              @words << 0x38646823 # ldrb w3, [x1, x4]
              has_load = true
            when Opcode::COPY
              @words << 0x2a0403e3 # mov w3, w4
            when Opcode::I32_EQZ
              @words << 0x7100009f # cmp w4, #0
              @words << 0x1a9f17e3 # cset w3, eq
            when Opcode::I32_ADD_IMM
              load_constant(5, c, false)
              emit_binary(Opcode::I32_ADD, 3, 4, 5)
            when Opcode::I32_ADD, Opcode::I32_SUB, Opcode::I32_EQ, Opcode::I32_NE
              return unless c.between?(0, types.size - 1) && types.fetch(c) == :i32
              load_loop_slot(5, c)
              emit_binary(op, 3, 4, 5)
            else
              return
            end
            @words << (0xf9000003 | (a << 10)) # str x3, [x0, #8*a]
            pc += width
          end
          return unless has_load
          condition = code.fetch(latch + 1)
          return unless condition.between?(0, types.size - 1) && types.fetch(condition) == :i32
          load_loop_slot(4, condition)
          @words << (0x35000004 | ((-@words.size & 0x7ffff) << 5)) # cbnz w4, head
          return_pc(latch + width)
          @words.pack("V*")
        end

        private

        # @rbs reg: Integer
        # @rbs slot: Integer
        # @rbs return: void
        def load_loop_slot(reg, slot)
          @words << (0xb9400000 | (slot << 11) | reg) # ldr wN, [x0, #8*slot]
        end

        # @rbs pc: Integer
        # @rbs return: void
        def return_pc(pc)
          load_constant(0, pc, false)
          @words << 0xd65f03c0 # ret
        end

        # @rbs branch_word: Integer
        # @rbs pc: Integer
        # @rbs return: void
        def exit_unless(branch_word, pc)
          index = @words.size
          @words << branch_word
          return_pc(pc)
          @words[index] = branch_word | ((@words.size - index) << 5)
        end
      end
    end
  end
end
