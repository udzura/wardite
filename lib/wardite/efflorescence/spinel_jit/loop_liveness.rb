# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    class SpinelJIT
      # Live MIR slots at native entry and at each VM continuation. Work on
      # verified flat code so a cache hit has the same information as a miss.
      class LoopLiveness
        include Opcode

        # @rbs function: Function
        def initialize(function)
          code = function.bytecode
          width = Lowerer::WIDTH
          @reads = [] #: Array[Array[Integer]]
          @writes = [] #: Array[Array[Integer]]
          @successors = [] #: Array[Array[Integer]]
          (code.size / width).times do |i|
            pc = i * width
            op, a, b, c = code.fetch(pc), code.fetch(pc + 1), code.fetch(pc + 2), code.fetch(pc + 3)
            if op == I64_BYTE_LOOKUP_BR_EQ
              # The fused VM handler commits the byte and decoded value only.
              # Its two temporary address slots are never written.
              @reads << [b, code.fetch(pc + 10), code.fetch(pc + 19)]
              @writes << [code.fetch(pc + 5), code.fetch(pc + 13)]
              @successors << [i + ByteSequences.length(op), code.fetch(pc + 18) / width]
              next
            end
            op = SEQUENCE_HEADS.fetch(op - I32_TABLE_STORE8) if op.between?(I32_TABLE_STORE8, I64_BYTE_LOOKUP_BR_EQ)
            insn = Instruction.new([op, a, b, c])
            @reads << (op == CALL ? function.call_site(b).arguments : function.reads(insn))
            dest = Opcode.destination(insn)
            writes = [] #: Array[Integer]
            writes << dest if dest >= 0
            @writes << writes
            edges = [] #: Array[Integer]
            edges << i + 1 unless Opcode.terminal?(op)
            pos = Opcode.target_position(insn)
            edges << insn[pos] / width if pos >= 0
            @successors << edges
          end
        end

        # @rbs members: Array[bool]
        # @rbs head: Integer
        # @rbs return: bool
        def single_entry?(members, head)
          @successors.each_with_index do |edges, i|
            next if members.fetch(i)
            edges.each { |target| return false if members.fetch(target) && target != head / Lowerer::WIDTH }
          end
          true
        end

        # @rbs slots: Array[Integer]
        # @rbs pcs: Array[Integer]
        # @rbs return: Hash[Integer, Array[Integer]]
        def at(slots, pcs)
          result = {} #: Hash[Integer, Array[Integer]]
          pcs.each { |pc| result[pc] = [] }
          # Each mask fits in Spinel's signed machine word, irrespective of
          # the parent frame size. Number bits in compact native buffer order.
          offset = 0
          while offset < slots.size
            bits = {} #: Hash[Integer, Integer]
            length = [60, slots.size - offset].min
            length.times { |bit| bits[slots.fetch(offset + bit)] = 1 << bit }
            gen = masks(@reads, bits)
            kill = masks(@writes, bits)
            live = gen.dup
            changed = true
            passes = 0
            while changed
              # Bound analysis time on irreducible control flow. Copying all
              # touched slots in this group is a conservative fallback.
              if passes == 32
                live.fill((1 << length) - 1)
                break
              end
              passes += 1
              changed = false
              i = live.size - 1
              while i >= 0
                out = 0
                @successors.fetch(i).each { |target| out |= live.fetch(target) }
                value = gen.fetch(i) | (out & ~kill.fetch(i))
                if value != live.fetch(i)
                  changed = true
                  live[i] = value
                end
                i -= 1
              end
            end
            pcs.each do |pc|
              mask = live.fetch(pc / Lowerer::WIDTH)
              length.times { |bit| result.fetch(pc) << offset + bit if mask[bit] != 0 }
            end
            offset += length
          end
          result
        end

        private

        # @rbs sets: Array[Array[Integer]]
        # @rbs bits: Hash[Integer, Integer]
        # @rbs return: Array[Integer]
        def masks(sets, bits)
          sets.map do |set|
            mask = 0
            set.each { |slot| mask |= bits.fetch(slot, 0) }
            mask
          end
        end
      end
    end
  end
end
