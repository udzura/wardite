# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    class SpinelJIT
      # Slots 0..14 live in x0..x14; larger slots occupy 8 bytes each at sp.
      # x15..x17 are caller-saved scratch. Writes to W registers zero-extend.
      class AArch64
        SCRATCH = 15
        LEFT = 16
        RIGHT = 17
        MAX_INSTRUCTIONS = 1024
        MAX_SLOTS = 128 # keeps the aligned leaf frame below one page
        OK = 0
        FALLBACK = 1
        BAILOUT = -1 # internal label, outside the MIR address space

        def initialize
          @words = [] #: Array[Integer]
          @labels = [] #: Array[Integer]
          @branches = {} #: Hash[Integer, Integer]
          @constant_slots = {} #: Hash[Integer, Integer]
          @types = [] #: Array[Symbol]
          @frame_size = 0
          @needs_bailout = false
        end

        # @rbs function: Function
        # @rbs return: String?
        def compile(function)
          params = function.parameter_types
          return unless (params == [:i32] || params == [:i32, :i32]) && function.result_types == [:i32]
          @types = function.register_types
          return unless @types.size <= MAX_SLOTS && @types.all? { |type| type == :i32 || type == :i64 }

          code = function.bytecode
          width = Lowerer::WIDTH
          return if code.empty? || code.size % width != 0 || code.size > MAX_INSTRUCTIONS * width
          return unless code.fetch(code.size - width) == Opcode::RETURN

          initialize_frame(function)
          pc = 0
          while pc < code.size
            @labels << @words.size
            op = code.fetch(pc)
            # The VM owns panic calls and their traps. Ordinary calls, memory
            # and other side effects remain ineligible for native execution.
            if op == Opcode::CALL
              return unless code[pc + width] == Opcode::TRAP
              branch(0x14000000, BAILOUT)
            else
              return unless emit(op, code.fetch(pc + 1), code.fetch(pc + 2), code.fetch(pc + 3), code.size)
            end
            pc += width
          end

          bailout_pc = @words.size
          if @needs_bailout
            finish_frame(FALLBACK)
          end
          @branches.each do |source, target|
            dest = target == BAILOUT ? bailout_pc : @labels.fetch(target / width)
            delta = dest - source
            word = @words.fetch(source)
            # B uses imm26. CBZ/CBNZ use imm19; the code size cap bounds both.
            @words[source] = word | (word == 0x14000000 ? (delta & 0x03ffffff) : ((delta & 0x7ffff) << 5))
          end
          @words.pack("V*")
        end

        private

        # @rbs function: Function
        # @rbs return: void
        def initialize_frame(function)
          # x2 holds the result pointer on entry and becomes MIR slot 2.
          # Keep it at [sp], with spill slots starting at [sp, #8].
          spilled = [function.register_count - SCRATCH, 0].max
          @frame_size = ((spilled + 1) * 8 + 15) & ~15
          @words << (0xd10003ff | (@frame_size << 10)) # sub sp, sp, #size
          @words << 0xf90003e2 # str x2, [sp]
          (function.parameter_count...function.register_count).each do |slot|
            value = function.initial_value(slot)
            reg = slot < SCRATCH ? slot : SCRATCH
            load_constant(reg, value, @types.fetch(slot) == :i64)
            store_slot(slot, reg)
            if slot < SCRATCH && @types.fetch(slot) == :i32 && function.constant_registers.include?(slot)
              @constant_slots[value] = slot
            end
          end
        end

        # @rbs status: Integer
        # @rbs return: void
        def finish_frame(status)
          @words << (0x52800000 | (status << 5)) # movz w0, #status
          @words << (0x910003ff | (@frame_size << 10)) # add sp, sp, #size
          @words << 0xd65f03c0 # ret
        end

        # @rbs dest: Integer
        # @rbs value: Integer
        # @rbs wide: bool
        # @rbs return: void
        def load_constant(dest, value, wide)
          size = wide ? 0x80000000 : 0
          @words << (size | 0x52800000 | ((value & 0xffff) << 5) | dest) # movz
          (1...(wide ? 4 : 2)).each do |part|
            bits = (value >> (part * 16)) & 0xffff
            @words << (size | 0x72800000 | (part << 21) | (bits << 5) | dest) unless bits == 0 # movk
          end
        end

        # @rbs value: Integer
        # @rbs return: Integer
        def constant_register(value)
          slot = @constant_slots[value]
          return slot if slot
          load_constant(SCRATCH, value, false)
          SCRATCH
        end

        # @rbs slot: Integer
        # @rbs scratch: Integer
        # @rbs return: Integer
        def read_slot(slot, scratch)
          return slot if slot < SCRATCH
          @words << (0xf94003e0 | ((slot - SCRATCH + 1) << 10) | scratch) # ldr xN, [sp, #offset]
          scratch
        end

        # @rbs slot: Integer
        # @rbs reg: Integer
        # @rbs return: void
        def store_slot(slot, reg)
          @words << (0xf90003e0 | ((slot - SCRATCH + 1) << 10) | reg) if slot >= SCRATCH
        end

        # @rbs word: Integer
        # @rbs target: Integer
        # @rbs return: void
        def branch(word, target)
          @branches[@words.size] = target
          @words << word
          @needs_bailout = true if target == BAILOUT
        end

        # @rbs op: Integer
        # @rbs a: Integer
        # @rbs b: Integer
        # @rbs c: Integer
        # @rbs length: Integer
        # @rbs return: bool
        def emit(op, a, b, c, length)
          if op == Opcode::TRAP
            branch(0x14000000, BAILOUT)
            return true
          end
          if op == Opcode::BR || op == Opcode::BR_IF || op == Opcode::BR_IF_ZERO
            target = op == Opcode::BR ? a : b
            return false unless target.between?(0, length - 1) && target % Lowerer::WIDTH == 0
            if op == Opcode::BR
              branch(0x14000000, target)
            else
              return false unless a.between?(0, @types.size - 1)
              branch((op == Opcode::BR_IF ? 0x35000000 : 0x34000000) | read_slot(a, LEFT), target)
            end
            return true
          end
          return false unless a.between?(0, @types.size - 1)
          if op == Opcode::RETURN
            @words << (0x2a0003e0 | (read_slot(a, LEFT) << 16)) # mov w0, wa
            @words << 0xf94003f1 # ldr x17, [sp]
            @words << 0xf9000220 # str x0, [x17] (zero-extended i32 result)
            finish_frame(OK)
            return true
          end

          return false unless b.between?(0, @types.size - 1)
          left = read_slot(b, LEFT)
          dest = a < SCRATCH ? a : SCRATCH
          case op
          when Opcode::COPY, Opcode::I64_EXTEND_I32_U
            # A W move implements unsigned extension, including in-place.
            base = op == Opcode::COPY && @types.fetch(a) == :i64 ? 0xaa0003e0 : 0x2a0003e0
            @words << (base | (left << 16) | dest)
          when Opcode::I32_XOR_SHL_IMM, Opcode::I32_XOR_SHR_U_IMM
            return false unless c.between?(0, 31)
            base = op == Opcode::I32_XOR_SHL_IMM ? 0x4a000000 : 0x4a400000
            @words << (base | (left << 16) | (c << 10) | (left << 5) | dest)
          when Opcode::I32_ADD_IMM, Opcode::I32_SUB_IMM
            if c.between?(0, 4095)
              base = op == Opcode::I32_ADD_IMM ? 0x11000000 : 0x51000000
              @words << (base | (c << 10) | (left << 5) | dest)
            else
              base = op == Opcode::I32_ADD_IMM ? 0x0b000000 : 0x4b000000
              @words << (base | (constant_register(c) << 16) | (left << 5) | dest)
            end
          when Opcode::I32_MUL_IMM
            @words << (0x1b007c00 | (constant_register(c) << 16) | (left << 5) | dest)
          else
            return false unless c.between?(0, @types.size - 1)
            return false unless emit_binary(op, dest, left, read_slot(c, RIGHT))
          end
          store_slot(a, dest)
          true
        end

        # @rbs op: Integer
        # @rbs dest: Integer
        # @rbs left: Integer
        # @rbs right: Integer
        # @rbs return: bool
        def emit_binary(op, dest, left, right)
          operands = (right << 16) | (left << 5) | dest
          case op
          when Opcode::I32_ADD then @words << (0x0b000000 | operands)
          when Opcode::I32_OR then @words << (0x2a000000 | operands)
          when Opcode::I64_MUL then @words << (0x9b007c00 | operands)
          when Opcode::I32_REM_U
            branch(0x34000000 | right, BAILOUT)
            @words << (0x1ac00800 | (right << 16) | (left << 5) | SCRATCH) # udiv
            @words << (0x1b008000 | (right << 16) | (left << 10) | (SCRATCH << 5) | dest) # msub
          when Opcode::I32_NE, Opcode::I32_LTU, Opcode::I32_GEU, Opcode::I32_GTU, Opcode::I64_GTU
            base = op == Opcode::I64_GTU ? 0xeb00001f : 0x6b00001f
            @words << (base | (right << 16) | (left << 5)) # cmp
            condition = case op
            when Opcode::I32_NE then 1  # ne
            when Opcode::I32_LTU then 3 # lo
            when Opcode::I32_GEU then 2 # hs
            else 8                     # hi
            end
            @words << (0x1a9f07e0 | ((condition ^ 1) << 12) | dest) # cset
          else
            return false
          end
          true
        end
      end
    end
  end
end
