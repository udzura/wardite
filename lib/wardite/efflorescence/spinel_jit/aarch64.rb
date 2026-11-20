# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    class SpinelJIT
      # MIR slot n lives in wn. w0 and w1 therefore receive the two arguments
      # directly. w15 is scratch. Larger register IDs fall back to the VM.
      class AArch64
        SCRATCH = 15
        # Keeps every generated branch within the signed imm19 range of CBZ.
        MAX_INSTRUCTIONS = 1024

        def initialize
          @words = [] #: Array[Integer]
          @labels = [] #: Array[Integer]
        end

        # Compile one complete lowered function. Branch targets in flat MIR
        # are word offsets; AArch64 branch displacements count instructions.
        # @rbs function: Function
        # @rbs return: String?
        def compile(function)
          return unless function.parameter_types == [:i32, :i32] && function.result_types == [:i32]
          return unless function.register_types.all? { |type| type == :i32 }

          code = function.bytecode
          width = Lowerer::WIDTH
          return if code.empty? || code.size % width != 0 || code.size > MAX_INSTRUCTIONS * width
          return unless code.fetch(code.size - width) == Opcode::RETURN

          # Frame initialization is outside every MIR label, including PC 0.
          (2...[function.register_count, SCRATCH].min).each do |slot|
            load_constant(slot, function.initial_value(slot))
          end
          pc = 0
          while pc < code.size
            @labels << @words.size
            return unless emit(code.fetch(pc), code.fetch(pc + 1), code.fetch(pc + 2), code.fetch(pc + 3), function.register_count)
            pc += width
          end
          pc = 0
          while pc < code.size
            op = code.fetch(pc)
            if op == Opcode::BR || op == Opcode::BR_IF_ZERO
              target = code.fetch(pc + (op == Opcode::BR ? 1 : 2))
              return if target < 0 || target >= code.size || target % width != 0
              source = @labels.fetch(pc / width)
              delta = @labels.fetch(target / width) - source
              if op == Opcode::BR
                @words[source] = 0x14000000 | (delta & 0x03ffffff) # b
              else
                @words[source] = 0x34000000 | ((delta & 0x7ffff) << 5) | code.fetch(pc + 1) # cbz
              end
            end
            pc += width
          end
          @words.pack("V*")
        end

        private

        # @rbs dest: Integer
        # @rbs value: Integer
        # @rbs return: void
        def load_constant(dest, value)
          @words << (0x52800000 | ((value & 0xffff) << 5) | dest) # movz
          high = (value >> 16) & 0xffff
          @words << (0x72a00000 | (high << 5) | dest) unless high == 0 # movk, lsl 16
        end

        # @rbs op: Integer
        # @rbs a: Integer
        # @rbs b: Integer
        # @rbs c: Integer
        # @rbs count: Integer
        # @rbs return: bool
        def emit(op, a, b, c, count)
          if op == Opcode::BR
            @words << 0 # resolved after emission
            return true
          end
          return false if a < 0 || a >= SCRATCH || a >= count
          case op
          when Opcode::RETURN
            @words << (0x2a0003e0 | (a << 16)) # mov w0, wa
            @words << 0xd65f03c0                # ret
          when Opcode::BR_IF_ZERO
            @words << 0
          else
            return false if b < 0 || b >= SCRATCH || b >= count
            case op
            when Opcode::COPY
              @words << (0x2a0003e0 | (b << 16) | a)
            when Opcode::I32_XOR_SHL_IMM, Opcode::I32_XOR_SHR_U_IMM
              return false unless c.between?(0, 31)
              base = op == Opcode::I32_XOR_SHL_IMM ? 0x4a000000 : 0x4a400000
              @words << (base | (b << 16) | (c << 10) | (b << 5) | a) # eor wa, wb, wb, shift
            when Opcode::I32_ADD_IMM, Opcode::I32_SUB_IMM
              if c.between?(0, 4095)
                base = op == Opcode::I32_ADD_IMM ? 0x11000000 : 0x51000000
                @words << (base | (c << 10) | (b << 5) | a)
              else
                load_constant(SCRATCH, c)
                base = op == Opcode::I32_ADD_IMM ? 0x0b000000 : 0x4b000000
                @words << (base | (SCRATCH << 16) | (b << 5) | a)
              end
            when Opcode::I32_MUL_IMM
              load_constant(SCRATCH, c)
              @words << (0x1b007c00 | (SCRATCH << 16) | (b << 5) | a)
            else
              return false
            end
          end
          true
        end
      end
    end
  end
end
