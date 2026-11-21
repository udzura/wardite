# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    module Passes
      class ConstantFolding
        include Opcode

        # Forward only immutable constant slots. Side tables keep their original
        # operands and count as reads when deciding whether a COPY is removable.
        # @rbs function: Function
        # @rbs return: void
        def run(function)
          return if function.constant_registers.empty?
          analysis = Analysis.new(function)
          function.handlers.each { |h| h.clauses.each { |c| analysis.leaders[c.target_pc] = 1 } }
          aliases = {} #: Hash[Integer, Integer]
          constants = Array.new(function.register_count, false)
          function.constant_registers.each { |r| constants[r] = true }
          copies = [] #: Array[Integer]
          function.instructions.each_with_index do |insn, pc|
            aliases.clear if analysis.leaders[pc] == 1
            unless aliases.empty?
              Opcode.read_positions(insn).each do |pos|
                old = insn[pos]
                slot = aliases.fetch(old, -1)
                next if slot < 0
                insn[pos] = slot
                analysis.reads[old] -= 1
                analysis.reads[slot] += 1
              end
            end
            dest = Opcode.destination(insn)
            next if dest < 0
            aliases.delete(dest)
            op = insn[0]
            if Opcode.pure_integer?(op) && constants[insn[2]]
              binary = Opcode.read_count(insn) == 2
              next if binary && !constants[insn[3]]
              left = function.initial_value(insn[2])
              right = binary ? function.initial_value(insn[3]) : (insn.size > 3 ? insn[3] : 0)
              result = calculate(op, left, right)
              slot = function.allocate_constant(result, type: function.register_types.fetch(dest))
              constants << true
              analysis.reads << 1
              Opcode.read_positions(insn).each { |pos| analysis.reads[insn[pos]] -= 1 }
              function.instructions[pc] = Instruction.new([COPY, dest, slot])
              aliases[dest] = slot
              copies << pc
            elsif op == COPY && constants[insn[2]]
              aliases[dest] = insn[2]
              copies << pc
            end
          end
          return unless copies.any? { |pc| analysis.reads.fetch(function.instructions.fetch(pc)[1]) == 0 }
          rewrite = Rewrite.new(function)
          function.instructions.each_with_index do |insn, pc|
            rewrite.mark(pc)
            rewrite.emit(insn) unless insn[0] == COPY && constants[insn[2]] && analysis.reads[insn[1]] == 0
          end
          rewrite.finish
        end

        # @rbs op: Integer
        # @rbs left: Integer
        # @rbs right: Integer
        # @rbs return: Integer
        def calculate(op, left, right)
          return I64Arithmetic.calculate(op, left, right) if op.between?(I64_EQZ, I64_MUL)
          op -= I32_ADD_IMM - I32_ADD if op.between?(I32_ADD_IMM, I32_SHR_U_IMM)
          case op
          when I32_ADD then (left + right) & 0xffffffff
          when I32_SUB then (left - right) & 0xffffffff
          when I32_MUL then I64Arithmetic.low(I64Arithmetic.multiply_i64(left, right))
          when I32_AND then left & right
          when I32_OR then left | right
          when I32_XOR then left ^ right
          when I32_SHL then (left << (right & 31)) & 0xffffffff
          when I32_SHR_U then left >> (right & 31)
          when I32_SHR_S then (I64Arithmetic.extend(left, 32) >> (right & 31)) & 0xffffffff
          when I32_ROTL, I32_ROTR
            count = (op == I32_ROTR ? -right : right) & 31
            ((left << count) & 0xffffffff) | (left >> (32 - count))
          when I32_EQZ then left == 0 ? 1 : 0
          when I32_EQ then left == right ? 1 : 0
          when I32_NE then left != right ? 1 : 0
          when I32_LTU then left < right ? 1 : 0
          when I32_GTU then left > right ? 1 : 0
          when I32_LEU then left <= right ? 1 : 0
          when I32_GEU then left >= right ? 1 : 0
          when I32_LTS then (left ^ 0x80000000) < (right ^ 0x80000000) ? 1 : 0
          when I32_GTS then (left ^ 0x80000000) > (right ^ 0x80000000) ? 1 : 0
          when I32_LES then (left ^ 0x80000000) <= (right ^ 0x80000000) ? 1 : 0
          when I32_GES then (left ^ 0x80000000) >= (right ^ 0x80000000) ? 1 : 0
          when I32_CLZ then I64Arithmetic.clz32(left)
          when I32_CTZ then I64Arithmetic.ctz32(left)
          when I32_POPCNT then I64Arithmetic.popcnt32(left)
          when I32_EXTEND8_S then I64Arithmetic.extend(left, 8) & 0xffffffff
          when I32_EXTEND16_S then I64Arithmetic.extend(left, 16) & 0xffffffff
          else raise TranslationError, "unsupported integer fold #{op}"
          end
        end
      end

      class ControlFlow
        include Opcode

        # @rbs function: Function
        # @rbs return: void
        def run(function)
          code = function.instructions
          return unless code.any? { |insn| Opcode.target_position(insn) >= 0 }
          constants = Array.new(function.register_count, false)
          function.constant_registers.each { |r| constants[r] = true }
          code.each_with_index do |insn, pc|
            op = insn[0]
            next unless (op == BR_IF || op == BR_IF_ZERO || op == BR_IF_I64_EQ) && constants[insn[1]]
            next if op == BR_IF_I64_EQ && !constants[insn[3]]
            value = function.initial_value(insn[1])
            taken = case op
                    when BR_IF then value != 0
                    when BR_IF_ZERO then value == 0
                    else value == function.initial_value(insn[3])
                    end
            code[pc] = Instruction.new([BR, taken ? insn[2] : pc + 1])
          end
          # Resolve jump chains once, including cycles (one self-loop suffices).
          target = Array.new(code.size, -1)
          path = [] #: Array[Integer]
          code.each_index do |pc|
            current = pc
            while target.fetch(current) == -1 && code.fetch(current)[0] == BR
              target[current] = -2
              path << current
              current = code.fetch(current)[1]
            end
            endpoint = target.fetch(current) >= 0 ? target.fetch(current) : current
            target[pc] = endpoint
            path.each { |entry| target[entry] = endpoint }
            path.clear
          end
          code.each do |insn|
            pos = Opcode.target_position(insn)
            insn[pos] = target.fetch(insn[pos]) if pos >= 0
          end
          live = Array.new(code.size, false)
          pending = [0]
          # Preserve every declared catch entry, even for an unused handler.
          function.handlers.each { |h| h.clauses.each { |c| pending << c.target_pc } }
          until pending.empty?
            pc = pending.pop || 0
            while pc < code.size && !live.fetch(pc)
              live[pc] = true
              insn = code.fetch(pc)
              pos = Opcode.target_position(insn)
              pending << insn[pos] if pos >= 0
              break if Opcode.terminal?(insn[0])
              pc += 1
            end
          end
          # A target reached through discarded code may now be fallthrough.
          following = code.size
          (code.size - 1).downto(0) do |pc|
            next unless live[pc]
            branch = code.fetch(pc)
            position = Opcode.target_position(branch)
            if position >= 0 && branch[position] == following
              live[pc] = false
            else
              following = pc
            end
          end
          return unless live.include?(false)
          rewrite = Rewrite.new(function)
          code.each_with_index do |insn, pc|
            rewrite.mark(pc)
            rewrite.emit(insn) if live[pc]
          end
          rewrite.finish
        end
      end

      class DeadCode
        # A pure definition can disappear when its slot has no remaining
        # readers anywhere. Revisit earlier definitions exposed by deletion.
        # @rbs function: Function
        # @rbs return: void
        def run(function)
          reads = Array.new(function.register_count, 0)
          code = function.instructions
          definitions = Array.new(function.register_count, -1)
          previous = Array.new(code.size, -1)
          code.each_with_index do |insn, pc|
            function.read_count(insn).times { |i| reads[function.read_at(insn, i)] += 1 }
            next unless insn[0] == Opcode::COPY || Opcode.pure_integer?(insn[0])
            slot = insn[1]
            previous[pc] = definitions[slot]
            definitions[slot] = pc
          end
          pending = [] #: Array[Integer]
          definitions.each_with_index { |pc, slot| pending << slot if pc >= 0 && reads[slot] == 0 }
          return if pending.empty?
          removed = Array.new(code.size, false)
          until pending.empty?
            slot = pending.pop || raise(TranslationError, "missing dead slot")
            pc = definitions.fetch(slot)
            while pc >= 0
              removed[pc] = true
              insn = code.fetch(pc)
              Opcode.read_positions(insn).each do |pos|
                source = insn[pos]
                reads[source] -= 1
                pending << source if reads[source] == 0 && definitions[source] >= 0
              end
              pc = previous.fetch(pc)
            end
          end
          rewrite = Rewrite.new(function)
          code.each_with_index do |insn, pc|
            rewrite.mark(pc)
            rewrite.emit(insn) unless removed[pc]
          end
          rewrite.finish
        end
      end

      class ExitCopies
        # A conditional exit often carries a constant error index. If the
        # fallthrough immediately overwrites the slot, only the taken edge
        # needs the assignment. Materialize it there, past the hot loop.
        # @rbs function: Function
        # @rbs return: void
        def run(function)
          # The measured case is a chain of fused i64 sentinel checks.
          return unless function.uses_store && function.uses_i64 && !function.uses_eh && function.handlers.empty?
          code = function.instructions
          targets = nil #: Array[bool]?
          moves = {} #: Hash[Integer, Integer]
          exits = {} #: Hash[Integer, Integer]
          code.each_with_index do |replacement, next_pc|
            next unless next_pc > 1 && replacement[0] == Opcode::COPY && replacement[1] != replacement[2]
            pc = next_pc - 1
            branch = code.fetch(pc)
            next unless branch[0] == Opcode::BR_IF_I64_EQ && branch[2] > next_pc
            load = code.fetch(pc - 1)
            next unless load[0] == Opcode::I64_LOAD8_U && (load[1] == branch[1] || load[1] == branch[3])
            slot = replacement[1]
            entries = targets ||= ByteSequences.entry_points(function)
            cursor = pc
            loop do
              insn = code.fetch(cursor)
              break if function.reads(insn).include?(slot)
              if Opcode.destination(insn) == slot
                if insn[0] == Opcode::COPY && function.constant_registers.include?(insn[2])
                  moves[cursor] = pc
                  exits[branch[2]] = exits.fetch(branch[2], 0) + 1
                end
                break
              end
              break if cursor == 0 || entries[cursor]
              cursor -= 1
              prev = code.fetch(cursor)
              break if Opcode.target_position(prev) >= 0 || Opcode.terminal?(prev[0])
            end
          end
          # A shared slow path amortizes its extra jump over several checks.
          moves.delete_if { |_, pc| exits.fetch(code.fetch(pc)[2]) < 2 }
          return if moves.empty?
          rewrite = Rewrite.new(function)
          code.each_with_index do |insn, pc|
            rewrite.mark(pc)
            rewrite.emit(insn) unless moves.key?(pc)
          end
          rewrite.finish
          output = function.instructions
          moves.each do |source, branch_pc|
            branch = code.fetch(branch_pc)
            target = branch[2]
            branch[2] = output.size
            output << code.fetch(source) << Instruction.new([Opcode::BR, target])
          end
        end
      end
    end
  end
end
