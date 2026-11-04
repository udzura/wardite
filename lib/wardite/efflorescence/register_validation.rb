# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    # Verify definite assignment once, after optimization and before execution.
    # This makes stale temporary slots harmless when a frame is reused. Keep
    # states per basic block, rather than per instruction, to bound their size.
    class RegisterValidation
      class Block
        attr_reader :first #: Integer
        attr_reader :limit #: Integer
        attr_reader :defined #: Array[Integer]

        # @rbs first: Integer
        # @rbs limit: Integer
        # @rbs register_count: Integer
        def initialize(first, limit, register_count)
          @first = first
          @limit = limit
          @defined = Array.new(register_count, 0)
          @reached = false
        end

        # Incoming facts only lose definitions after the first reachable edge.
        # A backedge cannot establish a definition missing on initial entry.
        # @rbs incoming: Array[Integer]
        # @rbs return: bool
        def merge(incoming)
          unless @reached
            @defined = incoming.dup
            @reached = true
            return true
          end
          changed = false
          index = 0
          while index < @defined.size
            if @defined[index] == 1 && incoming[index] == 0
              @defined[index] = 0
              changed = true
            end
            index += 1
          end
          changed
        end
      end

      # @rbs function: Wardite::Efflorescence::Function
      # @rbs return: void
      def validate(function)
        instructions = function.instructions
        raise TranslationError, "Efflorescence: empty MIR function" if instructions.empty?
        analysis = Analysis.new(function)
        blocks = [] #: Array[Wardite::Efflorescence::RegisterValidation::Block]
        block_for_pc = [] #: Array[Integer]
        first = 0
        instructions.size.times do |pc|
          if pc > 0 && analysis.leaders[pc] == 1
            blocks << Block.new(first, pc, function.register_count)
            first = pc
          end
          block_for_pc << blocks.size
        end
        blocks << Block.new(first, instructions.size, function.register_count)

        constants = Array.new(function.register_count, 0)
        defined = Array.new(function.register_count, 0)
        index = 0
        while index < function.parameter_count + function.local_count
          defined[index] = 1
          index += 1
        end
        function.constant_registers.each do |register|
          constants[register] = 1
          defined[register] = 1
        end
        blocks.fetch(0).merge(defined)
        pending = [] #: Array[Integer]
        pending << 0
        until pending.empty?
          block_index = pending.pop || raise(TranslationError, "missing MIR block")
          block = blocks.fetch(block_index)
          defined = block.defined.dup
          pc = block.first
          while pc < block.limit
            instruction = instructions.fetch(pc)
            Opcode.read_positions(instruction).each do |position|
              register = instruction[position]
              unless register >= 0 && register < defined.size && defined[register] == 1
                raise TranslationError, "Efflorescence: function #{function.index}, MIR PC #{pc}: r#{register} read before definition"
              end
            end
            destination = Opcode.destination(instruction)
            if destination >= 0
              if destination >= defined.size || constants[destination] == 1
                raise TranslationError, "Efflorescence: function #{function.index}, MIR PC #{pc}: invalid register destination r#{destination}"
              end
              defined[destination] = 1
            end
            pc += 1
          end
          last = instructions.fetch(block.limit - 1)
          target_position = Opcode.target_position(last)
          if target_position >= 0
            target = block_for_pc.fetch(last[target_position])
            pending << target if blocks.fetch(target).merge(defined)
          end
          unless last[0] == Opcode::BR || last[0] == Opcode::RETURN || last[0] == Opcode::TRAP
            next_block = block_index + 1
            if next_block >= blocks.size
              raise TranslationError, "Efflorescence: function #{function.index} falls through without RETURN"
            end
            pending << next_block if blocks.fetch(next_block).merge(defined)
          end
        end
      end
    end
  end
end
