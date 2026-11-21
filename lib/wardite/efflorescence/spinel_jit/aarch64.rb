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
          @uses_float = false
        end

        # @rbs function: Function
        # @rbs return: String?
        def compile(function)
          return unless function.result_types.size == 1 && FunctionEntry.numeric_type?(function.result_types.fetch(0))
          @types = function.register_types
          return unless @types.size <= MAX_SLOTS && @types.all? { |type| FunctionEntry.numeric_type?(type) }
          @uses_float = @types.any? { |type| FloatBits.float_type?(type) }

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
            # B uses imm26. Conditional branches use imm19; the code size cap bounds both.
            @words[source] = word | (word == 0x14000000 ? (delta & 0x03ffffff) : ((delta & 0x7ffff) << 5))
          end
          @words.pack("V*")
        end

        private

        # @rbs function: Function
        # @rbs return: void
        def initialize_frame(function)
          # Save the argument/result buffer before assigning x0 to MIR slot 0.
          # [sp] holds the pointer; spill slots start at [sp, #8].
          save_float_environment if @uses_float
          spilled = [function.register_count - SCRATCH, 0].max
          @frame_size = ((spilled + 1) * 8 + 15) & ~15
          @words << (0xd10003ff | (@frame_size << 10)) # sub sp, sp, #size
          @words << 0xf90003e0 # str x0, [sp]
          @words << 0xaa0003f1 # mov x17, x0
          function.parameter_count.times do |slot|
            reg = slot < SCRATCH ? slot : SCRATCH
            @words << (0xf9400000 | (slot << 10) | (RIGHT << 5) | reg) # ldr xN, [x17, #offset]
            store_slot(slot, reg)
          end
          (function.parameter_count...function.register_count).each do |slot|
            value = function.initial_value(slot)
            reg = slot < SCRATCH ? slot : SCRATCH
            load_constant(reg, value, wide_slot?(slot))
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
          restore_float_environment if @uses_float
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
            base = wide_slot?(a) ? 0xaa0003e0 : 0x2a0003e0
            @words << (base | (read_slot(a, LEFT) << 16)) # mov x0/w0, result
            @words << 0xf94003f1 # ldr x17, [sp]
            @words << 0xf9000220 # str x0, [x17]
            finish_frame(OK)
            return true
          end

          return false unless b.between?(0, @types.size - 1)
          left = read_slot(b, LEFT)
          dest = a < SCRATCH ? a : SCRATCH
          if op.between?(Opcode::F32_EQ, Opcode::F64_REINTERPRET_I64)
            return false unless emit_float(op, dest, left, c)
            store_slot(a, dest)
            return true
          end
          case op
          when Opcode::COPY, Opcode::I64_EXTEND_I32_U, Opcode::I32_WRAP_I64
            # A W move implements unsigned extension, including in-place.
            base = op == Opcode::COPY && wide_slot?(a) ? 0xaa0003e0 : 0x2a0003e0
            @words << (base | (left << 16) | dest)
          when Opcode::I32_EQZ, Opcode::I64_EQZ
            base = op == Opcode::I64_EQZ ? 0xf100001f : 0x7100001f
            @words << (base | (left << 5)) # cmp left, #0
            @words << (0x1a9f17e0 | dest) # cset wD, eq
          when Opcode::I64_EXTEND8_S, Opcode::I64_EXTEND16_S, Opcode::I64_EXTEND32_S, Opcode::I64_EXTEND_I32_S
            last_bit = case op
            when Opcode::I64_EXTEND8_S then 7
            when Opcode::I64_EXTEND16_S then 15
            else 31
            end
            @words << (0x93400000 | (last_bit << 10) | (left << 5) | dest) # sbfm xD, xN, #0, #last_bit
          when Opcode::I64_CLZ
            @words << (0xdac01000 | (left << 5) | dest)
          when Opcode::I64_CTZ
            @words << (0xdac00000 | (left << 5) | dest) # rbit
            @words << (0xdac01000 | (dest << 5) | dest) # clz
          when Opcode::I64_POPCNT
            @words << (0x9e670000 | (left << 5)) # fmov d0, xN
            @words << 0x0e205800 # cnt v0.8b, v0.8b
            @words << 0x0e31b800 # addv b0, v0.8b
            @words << (0x0e013c00 | dest) # umov wD, v0.b[0]
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
          when Opcode::I32_SUB then @words << (0x4b000000 | operands)
          when Opcode::I32_OR then @words << (0x2a000000 | operands)
          when Opcode::I64_ADD then @words << (0x8b000000 | operands)
          when Opcode::I64_SUB then @words << (0xcb000000 | operands)
          when Opcode::I64_AND then @words << (0x8a000000 | operands)
          when Opcode::I64_OR then @words << (0xaa000000 | operands)
          when Opcode::I64_XOR then @words << (0xca000000 | operands)
          when Opcode::I64_SHL then @words << (0x9ac02000 | operands)
          when Opcode::I64_SHR_U then @words << (0x9ac02400 | operands)
          when Opcode::I64_SHR_S then @words << (0x9ac02800 | operands)
          when Opcode::I64_ROTR then @words << (0x9ac02c00 | operands)
          when Opcode::I64_ROTL
            @words << (0xcb0003e0 | (right << 16) | SCRATCH) # neg x15, shift
            @words << (0x9ac02c00 | (SCRATCH << 16) | (left << 5) | dest) # rorv
          when Opcode::I64_MUL then @words << (0x9b007c00 | operands)
          when Opcode::I32_REM_U, Opcode::I64_REM_U, Opcode::I64_REM_S, Opcode::I64_DIV_U, Opcode::I64_DIV_S
            size = op == Opcode::I32_REM_U ? 0 : 0x80000000
            branch(size | 0x34000000 | right, BAILOUT) # cbz
            if op == Opcode::I64_DIV_S
              # Negating MIN sets V. Only then test whether the divisor is -1.
              @words << (0xeb0003ff | (left << 16)) # cmp xzr, left
              @words << (0xba416800 | (right << 5)) # ccmn right, #1, #0, vs
              branch(0x54000000, BAILOUT) # b.eq
            end
            div = op == Opcode::I64_DIV_S || op == Opcode::I64_REM_S ? 0x1ac00c00 : 0x1ac00800
            if op == Opcode::I64_DIV_S || op == Opcode::I64_DIV_U
              @words << (size | div | operands)
            else
              @words << (size | div | (right << 16) | (left << 5) | SCRATCH)
              @words << (size | 0x1b008000 | (right << 16) | (left << 10) | (SCRATCH << 5) | dest) # msub
            end
          when Opcode::I32_EQ, Opcode::I32_NE, Opcode::I32_LTU, Opcode::I32_GEU, Opcode::I32_GTU,
               Opcode::I64_EQ, Opcode::I64_NE, Opcode::I64_LTS, Opcode::I64_LTU, Opcode::I64_GTS,
               Opcode::I64_GTU, Opcode::I64_LES, Opcode::I64_LEU, Opcode::I64_GES, Opcode::I64_GEU
            base = op >= Opcode::I64_EQ ? 0xeb00001f : 0x6b00001f
            @words << (base | (right << 16) | (left << 5)) # cmp
            condition = case op
            when Opcode::I32_EQ, Opcode::I64_EQ then 0   # eq
            when Opcode::I32_NE, Opcode::I64_NE then 1   # ne
            when Opcode::I32_GEU, Opcode::I64_GEU then 2 # hs
            when Opcode::I32_LTU, Opcode::I64_LTU then 3 # lo
            when Opcode::I32_GTU, Opcode::I64_GTU then 8 # hi
            when Opcode::I64_LEU then 9  # ls
            when Opcode::I64_GES then 10 # ge
            when Opcode::I64_LTS then 11 # lt
            when Opcode::I64_GTS then 12 # gt
            else 13                      # le
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

require_relative "aarch64_float"
