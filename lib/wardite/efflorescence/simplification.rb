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
    end
  end
end
