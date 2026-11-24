# frozen_string_literal: true
# rbs_inline: enabled

require_relative "loop_liveness"

module Wardite
  module Efflorescence
    class SpinelJIT
      class LookupLoop
        attr_reader :code #: String
        attr_reader :slots #: Array[Integer]
        attr_reader :inputs #: Array[Integer]
        attr_reader :outputs #: Hash[Integer, Array[Integer]]

        # @rbs code: String
        # @rbs slots: Array[Integer]
        # @rbs inputs: Array[Integer]
        # @rbs outputs: Hash[Integer, Array[Integer]]
        def initialize(code, slots, inputs, outputs)
          @code, @slots, @inputs, @outputs = code, slots, inputs, outputs
        end
      end

      class LookupSite
        HOT_BACKEDGES = 1024 # 24 KiB of binary data in either bulk loop

        def initialize
          @remaining = HOT_BACKEDGES
          @loop = nil #: LookupLoop?
          @page = 0
        end

        # @rbs frame: Frame
        # @rbs pc: Integer
        # @rbs memory: IO::Buffer
        # @rbs return: Integer
        def run(frame, pc, memory)
          head = frame.instructions.fetch(pc + 2)
          if @remaining > 0
            @remaining -= 1
            return head if @remaining > 0
            @loop = LookupLoopCompiler.new(frame.function).compile_loop(head, pc)
          end
          loop = @loop
          @page = Native.wardite_jit_map_code(loop.code, loop.code.bytesize) if loop && @page == 0
          unless loop && @page != 0
            frame.instructions[pc] = Opcode::BR_IF
            return head
          end
          slots = loop.slots
          buffer = IO::Buffer.new((slots.size + 1) * 8)
          loop.inputs.each { |i| buffer.set_value(:s64, i * 8, frame.registers.fetch(slots.fetch(i))) }
          resume = Native.wardite_jit_call_loop(@page, buffer, memory, memory.size)
          outputs = loop.outputs.fetch(resume)
          outputs.each { |i| frame.registers[slots.fetch(i)] = Integer(buffer.get_value(:s64, i * 8)) }
          if ENV["WARDITE_TRACE"]
            turns = Integer(buffer.get_value(:s64, slots.size * 8))
            warn "MIR JIT lookup loop function #{frame.function.index}: backedge #{pc / Lowerer::WIDTH}, native exit #{resume / Lowerer::WIDTH}, iterations #{turns}, inputs #{loop.inputs.size}, outputs #{outputs.size}"
          end
          resume
        end

        # @rbs return: void
        def release
          loop = @loop
          Native.wardite_jit_unmap_code(@page, loop.code.bytesize) if loop && @page != 0
          @page = 0
        end
      end

      # A single taken backedge can cover an unrolled sequence of table reads
      # with cold panic/error blocks between them. Follow forward conditional
      # targets inside the loop; guard their fallthrough back to the VM.
      class LookupLoopCompiler < AArch64
        include Opcode
        CACHE_REGISTERS = 10 # x6..x15; x0..x2 are the ABI, x3..x5 scratch, x17 counts iterations.
        MAX_WORDS = 8192
        MAX_FRAME = 2048
        MAX_FUNCTION = 4096
        MAX_SPAN = 512

        # @rbs function: Function
        def initialize(function)
          super()
          @function = function
          @code = function.bytecode
          @positions = {} #: Hash[Integer, Integer]
          @guards = {} #: Hash[Integer, Integer]
          @modified = [] #: Array[Integer]
        end

        # @rbs head: Integer
        # @rbs latch: Integer
        # @rbs return: LookupLoop?
        def compile_loop(head, latch)
          path = [] #: Array[Integer]
          counts = Array.new(@function.register_count, 0)
          members = Array.new(@code.size / Lowerer::WIDTH, false)
          has_lookup = false
          pc = head
          while pc <= latch
            members[pc / Lowerer::WIDTH] = true
            path << pc
            op = @code.fetch(pc)
            insn = Instruction.new(@code[pc, Lowerer::WIDTH] || raise(IndexError))
            if op == I64_BYTE_LOOKUP_BR_EQ
              has_lookup = true
              ByteSequences.length(op).times { |i| members[pc / Lowerer::WIDTH + i] = true }
              [2, 10, 19, 5, 13].each { |pos| counts[@code.fetch(pc + pos)] += 1 }
              @modified << @code.fetch(pc + 5) << @code.fetch(pc + 13)
              pc += ByteSequences.length(op) * Lowerer::WIDTH
              next
            end
            has_lookup = true if op == I32_TABLE_STORE8
            return unless supported?(op)
            Opcode.read_positions(insn).each { |pos| counts[insn[pos]] += 1 }
            dest = Opcode.destination(insn)
            if dest >= 0
              counts[dest] += 1
              @modified << dest
            end
            target = insn[2]
            pc = op == BR_IF && target > pc && target <= latch ? target : pc + Lowerer::WIDTH
          end
          return unless has_lookup && path.last == latch
          flow = LoopLiveness.new(@function)
          return unless flow.single_entry?(members, head)
          slots = (0...counts.size).select { |s| counts.fetch(s) > 0 }.sort_by { |s| -counts.fetch(s) }
          return unless slots.all? { |s| [:i32, :i64].include?(@function.register_types.fetch(s)) }
          slots.each_with_index { |slot, i| @positions[slot] = i }

          # The first ten compact slots stay in GPRs, including loop-carried
          # pointers and the frequently reused byte/packed-bit intermediates.
          cached = [CACHE_REGISTERS, slots.size].min
          cached.times { |i| @words << (0xf9400000 | (i << 10) | (6 + i)) }
          @words << 0xaa1f03f1 # mov x17, xzr (native iterations entered)
          start = @words.size
          @words << 0x91000631 # add x17, x17, #1
          path.each do |pos|
            return unless emit_member(pos, latch, start)
          end
          normal = latch + Lowerer::WIDTH
          exits = ([normal] + @guards.values).uniq
          # Each guard returns its original MIR word PC through one epilogue.
          stubs = {} #: Hash[Integer, Integer]
          jumps = [] #: Array[Integer]
          exits.each do |target|
            stubs[target] = @words.size
            load_constant(3, target, false)
            jumps << @words.size
            @words << 0x14000000
          end
          jumps.each { |i| @words[i] |= @words.size - i }
          @guards.each { |i, target| @words[i] |= ((stubs.fetch(target) - i) << 5) }
          cached.times { |i| @words << (0xf9000000 | (i << 10) | (6 + i)) }
          @words << (0xf9000011 | (slots.size << 10)) # str x17, [x0, #count]
          @words << 0x2a0303e0 << 0xd65f03c0 # mov w0, w3; ret
          return if @words.size > MAX_WORDS
          live = flow.at(slots, (exits + [head]).uniq)
          outputs = {} #: Hash[Integer, Array[Integer]]
          written = Array.new(slots.size, false)
          @modified.each { |slot| written[@positions.fetch(slot)] = true }
          exits.each { |target| outputs[target] = live.fetch(target).select { |i| written.fetch(i) } }
          LookupLoop.new(@words.pack("V*"), slots, live.fetch(head), outputs)
        end

        private

        # @rbs op: Integer
        # @rbs return: bool
        def supported?(op)
          case op
          when BR_IF, BR_IF_I64_EQ, I64_BYTE_LOOKUP, I32_LOAD8_U, I64_LOAD8_U,
               I64_STORE16, I64_STORE32, COPY, I32_ADD_IMM, I32_ADD, I32_NE,
               I64_SHL, I64_SHR_U, I64_OR, I64_AND, I64_NE, I64_LOAD, I32_STORE8,
               I32_TABLE_STORE8, I32_WRAP_I64, I32_EXTRACT_I64, I32_SHR_U_IMM,
               I32_AND, I32_GTU, I32_LEU then true
          else false
          end
        end

        # @rbs slot: Integer
        # @rbs scratch: Integer
        # @rbs return: Integer
        def source(slot, scratch)
          i = @positions.fetch(slot)
          return 6 + i if i < CACHE_REGISTERS
          @words << (0xf9400000 | (i << 10) | scratch)
          scratch
        end

        # @rbs slot: Integer
        # @rbs reg: Integer
        # @rbs return: void
        def write(slot, reg)
          i = @positions.fetch(slot)
          if i < CACHE_REGISTERS
            @words << (0xaa0003e0 | (reg << 16) | (6 + i))
          else
            @words << (0xf9000000 | (i << 10) | reg)
          end
        end

        # @rbs word: Integer
        # @rbs pc: Integer
        # @rbs return: void
        def guard(word, pc)
          @guards[@words.size] = pc
          @words << word
        end

        # @rbs address: Integer
        # @rbs pc: Integer
        # @rbs return: void
        def check_byte(address, pc)
          @words << (0xeb02001f | (address << 5)) # cmp address, x2
          guard(0x54000002, pc) # b.hs
        end

        # @rbs pc: Integer
        # @rbs latch: Integer
        # @rbs start: Integer
        # @rbs return: bool
        def emit_member(pc, latch, start)
          op, a, b, c = @code.fetch(pc), @code.fetch(pc + 1), @code.fetch(pc + 2), @code.fetch(pc + 3)
          if op == BR_IF
            cond = source(a, 3)
            if pc == latch
              @words << (0x35000000 | (((start - @words.size) & 0x7ffff) << 5) | cond)
            elsif b > pc && b <= latch
              guard(0x34000000 | cond, pc + Lowerer::WIDTH) # cbz: cold fallthrough
            else
              guard(0x35000000 | cond, b)
            end
          elsif op == BR_IF_I64_EQ
            lhs = source(a, 3)
            rhs = source(c, 4)
            @words << (0xeb00001f | (rhs << 16) | (lhs << 5))
            guard(0x54000000, b)
          elsif op == I64_BYTE_LOOKUP_BR_EQ
            emit_lookup(pc)
          elsif op == I32_STORE8 || op == I64_STORE16 || op == I64_STORE32
            bytes, store = case op
            when I32_STORE8 then [1, 0x38246820]
            when I64_STORE16 then [2, 0x78246820]
            else [4, 0xb8246820]
            end
            checked_address(source(b, 4), c, bytes, pc)
            @words << (store | source(a, 3))
          else
            left = source(b, 4)
            case op
            when I32_LOAD8_U, I64_LOAD8_U, I64_LOAD
              wide = op == I64_LOAD
              checked_address(left, c, wide ? 8 : 1, pc)
              @words << (wide ? 0xf8646823 : 0x38646823) # ldr x3 / ldrb w3, [x1, x4]
            when I32_TABLE_STORE8
              # Its three remaining flat instructions run in order, with their own trap PCs.
              emit_binary(I32_ADD, 3, left, source(c, 5))
            when I32_WRAP_I64
              @words << (0x2a0003e3 | (left << 16)) # mov w3, wLeft
            when I32_SHR_U_IMM
              @words << (0x53007c03 | ((c & 31) << 16) | (left << 5)) # lsr w3, wLeft, #shift
            when I32_EXTRACT_I64
              @words << (0x9340fc03 | ((c & 63) << 16) | (left << 5)) # asr x3, xLeft, #shift
              load_constant(5, c >> 6, false)
              emit_binary(I32_AND, 3, 3, 5)
            when I32_ADD_IMM, I64_BYTE_LOOKUP
              load_constant(5, c, false)
              emit_binary(I32_ADD, 3, left, 5)
            when COPY
              @words << (0xaa0003e3 | (left << 16))
            else
              return false unless emit_binary(op, 3, left, source(c, 5))
            end
            write(a, 3)
          end
          true
        end

        # Form the effective address in x4 without wrapping the 32-bit base.
        # Check the final byte before performing an unaligned multi-byte access.
        # @rbs base: Integer
        # @rbs offset: Integer
        # @rbs bytes: Integer
        # @rbs pc: Integer
        # @rbs return: void
        def checked_address(base, offset, bytes, pc)
          load_constant(5, offset, false)
          @words << (0x8b2040a4 | (base << 16)) # add x4, x5, wBase, uxtw
          if bytes == 1
            check_byte(4, pc)
          else
            @words << (0x91000085 | ((bytes - 1) << 10)) # add x5, x4, #last
            check_byte(5, pc)
          end
        end

        # Match the atomic VM handler: on either bounds failure no output
        # slot has been written. The error comparison observes both commits.
        # @rbs pc: Integer
        # @rbs return: void
        def emit_lookup(pc)
          base = source(@code.fetch(pc + 2), 4)
          load_constant(5, @code.fetch(pc + 3), false)
          emit_binary(I32_ADD, 4, base, 5)
          check_byte(4, pc)
          @words << 0x38646823 # ldrb w3, [x1, x4]
          table = source(@code.fetch(pc + 10), 4)
          emit_binary(I32_ADD, 4, table, 3)
          check_byte(4, pc)
          @words << 0x38646825 # ldrb w5, [x1, x4]
          write(@code.fetch(pc + 5), 3)
          write(@code.fetch(pc + 13), 5)
          key = source(@code.fetch(pc + 19), 4)
          @words << (0xeb0000bf | (key << 16)) # cmp x5, key
          guard(0x54000000, @code.fetch(pc + 18))
        end
      end
    end
  end
end
