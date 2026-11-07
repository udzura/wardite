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
        validate_types(function)
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
            function.reads(instruction).each do |register|
              unless register >= 0 && register < defined.size && defined[register] == 1
                raise TranslationError, "Efflorescence: function #{function.index}, MIR PC #{pc}: r#{register} read before definition"
              end
            end
            # Exceptional writes are edge-local. In particular a CALL result
            # is absent here, even though its normal successor defines it.
            analysis.flow.exceptional.fetch(pc).each do |clause|
              edge_defined = defined.dup
              clause.destinations.each { |register| edge_defined[register] = 1 }
              target = block_for_pc.fetch(clause.target_pc)
              pending << target if blocks.fetch(target).merge(edge_defined)
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
          analysis.flow.normal.fetch(block.limit - 1).each do |pc|
            target = block_for_pc.fetch(pc)
            pending << target if blocks.fetch(target).merge(defined)
          end
        end
      end
      private

      # Validate all registers, including unreachable instructions and table-only
      # operands. The runtime never needs to branch on an i32 register's type.
      # @rbs function: Wardite::Efflorescence::Function
      # @rbs return: void
      def validate_types(function)
        function.instructions.each do |instruction|
          opcode = instruction[0]
          if Opcode.memory_site?(opcode)
            index = instruction[1]
            unless index >= 0 && index < function.memory_sites.size
              raise TranslationError, "invalid MIR memory site index"
            end
            site = function.memory_site(index)
            unless site.sources.size == 3 && site.memory_index == 0 && site.source_memory_index == 0 &&
                (opcode != Opcode::MEMORY_INIT || site.data_index >= 0)
              raise TranslationError, "invalid MIR memory site operands"
            end
          end
          if Opcode.dynamic_call?(opcode)
            site = function.dynamic_site(instruction[2])
            destination = instruction[1]
            unless site.arguments.size == site.parameter_types.size && site.parameter_types.all? { |type| type == :i32 } &&
                (site.result_types.empty? ? destination == -1 : site.result_types == [:i32] && destination >= 0)
              raise TranslationError, "invalid MIR dynamic call signature"
            end
          end
          reads = function.reads(instruction)
          destination = Opcode.destination(instruction)
          expected = opcode == Opcode::COPY_REF || opcode == Opcode::THROW_REF ? :exnref : :i32
          (reads + (destination >= 0 ? [destination] : [])).each do |register|
            unless register >= 0 && function.register_types[register] == expected
              raise TranslationError, "invalid MIR register type/index r#{register}"
            end
          end
        end
        function.handlers.each do |handler|
          handler.clauses.each do |clause|
            clause.payload_registers.each { |register| check_destination(function, register, :i32) }
            check_destination(function, clause.reference_register, :exnref) if clause.reference_register >= 0
          end
        end
      end

      # @rbs function: Wardite::Efflorescence::Function
      # @rbs register: Integer
      # @rbs type: Symbol
      # @rbs return: void
      def check_destination(function, register, type)
        unless register >= 0 && function.register_types[register] == type && !function.constant_registers.include?(register)
          raise TranslationError, "invalid catch destination r#{register}"
        end
      end

    end
  end
end
