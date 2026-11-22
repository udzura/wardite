# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    module Passes
      class LoopInvariants
        # @rbs function: Function
        # @rbs return: void
        def run(function)
          return if function.uses_eh || !function.handlers.empty?
          code = function.instructions
          edges = [] #: Array[Integer]
          latches = [] #: Array[Integer]
          code.each_with_index do |insn, pc|
            pos = Opcode.target_position(insn)
            next if pos < 0
            edges << pc
            latches << pc if insn[pos] < pc
          end
          return if latches.empty?

          analysis = Analysis.new(function)
          first_read = Array.new(function.register_count, code.size)
          last_read = Array.new(function.register_count, -1)
          code.each_with_index do |insn, pc|
            function.read_count(insn).times do |i|
              slot = function.read_at(insn, i)
              first_read[slot] = pc if pc < first_read[slot]
              last_read[slot] = pc
            end
          end
          # Preserve the same four-op groups that the subsequent byte fusion
          # pass can use. Their intermediate writes remain observable in MIR.
          grouped = Array.new(code.size, false)
          if function.uses_store
            (0...code.size - 3).each do |pc|
              head = code.fetch(pc)
              next if ByteSequences.match(head[0], head, code.fetch(pc + 1), code.fetch(pc + 2), code.fetch(pc + 3)) < 0
              ByteSequences::LENGTH.times { |offset| grouped[pc + offset] = true }
            end
          end
          preheaders = {} #: Hash[Integer, Array[Instruction]]
          moved = Array.new(code.size, false)
          # Latches arrive in program order. Handle disjoint loops only.
          previous_end = -1
          latches.each do |latch_pc|
            last = Integer(latch_pc)
            latch = code.fetch(last)
            first = latch[Opcode.target_position(latch)]
            next if first <= previous_end
            # All external entries must be fallthrough into the preheader.
            next if edges.any? do |pc|
              edge = code.fetch(pc)
              source = Integer(pc)
              target = edge[Opcode.target_position(edge)]
              (source < first || source > last) && target >= first && target <= last
            end
            stable = Array.new(function.register_count, false)
            (function.parameter_count + function.local_count).times { |r| stable[r] = true }
            function.constant_registers.each { |r| stable[r] = true }
            pc = first - 1
            while pc >= 0
              defined_slot = Opcode.destination(code.fetch(pc))
              stable[defined_slot] = true if defined_slot >= 0
              break if analysis.leaders[pc] == 1
              pc -= 1
            end
            (first..last).each do |i|
              dest = Opcode.destination(code.fetch(i))
              stable[dest] = false if dest >= 0
            end
            hoisted = [] #: Array[Instruction]
            (first..last).each do |i|
              insn = code.fetch(i)
              next if grouped[i] || !Opcode.pure_integer?(insn[0])
              dest = insn[1]
              next if dest < function.parameter_count + function.local_count || analysis.writes[dest] != 1
              next unless first_read[dest] >= first && last_read[dest].between?(first, last)
              next unless Opcode.read_positions(insn).all? { |pos| stable[insn[pos]] }
              # A fresh temporary with no outside reads can also be assigned
              # on a zero-trip path. Never overwrite a Wasm local speculatively.
              hoisted << insn
              moved[i] = true
              stable[dest] = true
            end
            unless hoisted.empty?
              preheaders[first] = hoisted
              previous_end = last
            end
          end
          return if preheaders.empty?
          rewrite = Rewrite.new(function)
          code.each_with_index do |insn, pc|
            prefix = preheaders[pc]
            prefix.each { |item| rewrite.emit(item) } if prefix
            rewrite.mark(pc)
            rewrite.emit(insn) unless moved[pc]
          end
          rewrite.finish
        end
      end
    end
  end
end
