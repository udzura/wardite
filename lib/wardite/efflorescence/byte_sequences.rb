# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    # Select short instruction sequences after register validation. Keeping all
    # operand slots preserves PCs for branches, catches, and snapshot frames.
    class ByteSequences
      include Opcode
      LENGTH = 4
      # Indexed in the same order as Opcode::SEQUENCE_HEADS.
      FORWARDED_READS = [2, 3, 3, 2, 2, 4].freeze #: Array[Integer]

      # @rbs function: Function
      # @rbs return: void
      def self.fuse(function)
        instructions = function.instructions
        targets = nil #: Array[bool]?
        uses = nil #: Array[Integer]?
        pc = 0
        while pc + LENGTH <= instructions.size
          first = instructions.fetch(pc)
          opcode = match(first[0], first, instructions.fetch(pc + 1), instructions.fetch(pc + 2), instructions.fetch(pc + 3))
          if opcode < 0
            pc += 1
            next
          end

          entries = targets ||= entry_points(function)
          if entries[pc + 1] || entries[pc + 2] || entries[pc + 3]
            pc += 1
            next
          end
          if opcode == I64_BYTE_LOOKUP && pc + LENGTH < instructions.size && !entries[pc + LENGTH] &&
              lookup_branch?(instructions.fetch(pc + 3), instructions.fetch(pc + LENGTH))
            counts = uses || read_counts(function)
            uses = counts
            opcode = I64_BYTE_LOOKUP_BR_EQ if dead_lookup_addresses?(function, pc, counts)
          end
          first[0] = opcode
          pc += length(opcode)
        end
      end

      # @rbs opcode: Integer
      # @rbs return: Integer
      def self.length(opcode)
        opcode == I64_BYTE_LOOKUP_BR_EQ ? LENGTH + 1 : LENGTH
      end

      # @rbs load: Instruction
      # @rbs branch: Instruction
      # @rbs return: bool
      def self.lookup_branch?(load, branch)
        branch[0] == BR_IF_I64_EQ && branch[1] == load[1]
      end

      # Only the two address slots lose writes. The early read of the table
      # base must also see the same value as the original sequence.
      # @rbs function: Function
      # @rbs pc: Integer
      # @rbs uses: Array[Integer]
      # @rbs return: bool
      def self.dead_lookup_addresses?(function, pc, uses)
        code = function.instructions
        first = code.fetch(pc)
        second = code.fetch(pc + 1)
        third = code.fetch(pc + 2)
        floor = function.parameter_count + function.local_count
        first[1] >= floor && third[1] >= floor && uses.fetch(first[1]) == 1 &&
          uses.fetch(third[1]) == 1 && third[2] != second[1] && third[2] != first[1]
      end

      # Include call arguments and side tables in the use counts.
      # @rbs function: Function
      # @rbs return: Array[Integer]
      def self.read_counts(function)
        counts = Array.new(function.register_count, 0)
        function.instructions.each do |op|
          function.read_count(op).times { |i| counts[function.read_at(op, i)] += 1 }
        end
        counts
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
        if head == I32_ADD_IMM && second[0] == I32_DIV_U && third[0] == I32_STORE8 && fourth[0] == I32_ADD_IMM &&
            second[2] == first[1] && third[1] == second[1]
          return I32_DIV_U_STORE8
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
