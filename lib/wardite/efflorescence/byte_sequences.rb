# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    # Select four-instruction sequences after register validation. Keeping all
    # operand slots preserves PCs for branches, catches, and snapshot frames.
    class ByteSequences
      include Opcode
      LENGTH = 4
      # Indexed in the same order as Opcode::SEQUENCE_HEADS.
      FORWARDED_READS = [2, 3, 3, 2].freeze #: Array[Integer]

      # @rbs function: Function
      # @rbs return: void
      def self.fuse(function)
        instructions = function.instructions
        targets = nil #: Array[bool]?
        pc = 0
        while pc + LENGTH <= instructions.size
          first = instructions.fetch(pc)
          opcode = match(first[0], first, instructions.fetch(pc + 1), instructions.fetch(pc + 2), instructions.fetch(pc + 3))
          if opcode >= 0
            entries = targets || entry_points(function)
            targets = entries
            unless entries[pc + 1] || entries[pc + 2] || entries[pc + 3]
              first[0] = opcode
              pc += LENGTH
              next
            end
          end
          pc += 1
        end
      end

      # Used both when lowering and when checking a restored bytecode body.
      # @rbs head: Integer
      # @rbs first: Instruction
      # @rbs second: Instruction
      # @rbs third: Instruction
      # @rbs fourth: Instruction
      # @rbs return: Integer
      def self.match(head, first, second, third, fourth)
        if head == I32_ADD && second[0] == I32_LOAD8_U && third[0] == I32_STORE8 && fourth[0] == I32_ADD_IMM &&
            second[2] == first[1] && third[1] == second[1]
          return I32_TABLE_STORE8
        end
        if head == I32_ADD_IMM && second[0] == I32_LOAD8_U && third[0] == I32_ADD && fourth[0] == I64_LOAD8_U &&
            second[2] == first[1] && third[3] == second[1] && fourth[2] == third[1] &&
            second[3] == 0 && fourth[3] == 0
          return I64_BYTE_LOOKUP
        end
        if head == I32_ADD_IMM && second[0] == I32_LOAD8_U && third[0] == I32_MUL_IMM && fourth[0] == I32_ADD &&
            second[2] == first[1] && third[2] == second[1] && fourth[3] == third[1] && second[3] == 0 &&
            third[3].between?(0, 0xffffffff)
          return I32_BYTE_MUL_ADD
        end
        if head == I32_LOAD8_U && second[0] == I32_ADD && third[0] == I32_STORE8 && fourth[0] == I32_ADD_IMM &&
            second[2] == first[1] && third[1] == second[1] && first[3] == 0 && third[3] == 0
          return I32_BYTE_ADD_STORE
        end
        -1
      end

      # @rbs function: Function
      # @rbs return: Array[bool]
      def self.entry_points(function)
        targets = Array.new(function.instructions.size, false) #: Array[bool]
        function.instructions.each do |insn|
          position = Opcode.target_position(insn)
          targets[insn[position]] = true if position >= 0
        end
        function.handlers.each do |handler|
          handler.clauses.each { |clause| targets[clause.target_pc] = true }
        end
        targets
      end
    end
  end
end
