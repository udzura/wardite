# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    # Verify definite assignment once, after optimization and before execution.
    # This makes stale temporary slots harmless when a frame is reused. Keep
    # states per basic block, rather than per instruction, to bound their size.
    class RegisterValidation
      # Keep each word within Spinel's fixed-width Integer.
      WORD_SHIFT = 5
      WORD_BITS = 1 << WORD_SHIFT
      WORD_MASK = WORD_BITS - 1

      class Block
        attr_reader :first #: Integer
        attr_reader :limit #: Integer
        attr_reader :defined #: Array[Integer]
        attr_reader :successors #: Array[Integer]
        attr_accessor :pending #: bool

        # @rbs first: Integer
        # @rbs limit: Integer
        def initialize(first, limit)
          @first = first
          @limit = limit
          @defined = [] #: Array[Integer]
          @successors = [] #: Array[Integer]
          @reached = false
          @pending = false
        end

        # Incoming facts only lose definitions after the first reachable edge.
        # Return true when a changed block needs to enter the worklist.
        # @rbs incoming: Array[Integer]
        # @rbs return: bool
        def merge(incoming)
          changed = false
          unless @reached
            @defined = incoming.dup
            @reached = true
            changed = true
          else
            index = 0
            while index < @defined.size
              previous = @defined.fetch(index)
              intersection = previous & incoming.fetch(index)
              if intersection != previous
                @defined[index] = intersection
                changed = true
              end
              index += 1
            end
          end
          return false unless changed && !@pending

          @pending = true
          true
        end
      end

      # @rbs function: Wardite::Efflorescence::Function
      # @rbs return: void
      # @rbs ir: Wardite::Efflorescence::IR?
      # @rbs tags: Array[Wardite::Efflorescence::Tag]?
      def validate(function, ir = nil, tags: nil)
        instructions = function.instructions
        raise TranslationError, "Efflorescence: empty MIR function" if instructions.empty?
        validate_types(function, ir, tags)
        analysis = Analysis.new(function)
        flow = analysis.flow
        register_count = function.register_count
        blocks = [] #: Array[Wardite::Efflorescence::RegisterValidation::Block]
        block_for_pc = [] #: Array[Integer]
        first = 0
        instructions.size.times do |pc|
          if pc > 0 && analysis.leaders[pc] == 1
            blocks << Block.new(first, pc)
            first = pc
          end
          block_for_pc << blocks.size
        end
        blocks << Block.new(first, instructions.size)
        order = reverse_postorder(blocks, block_for_pc, flow)

        word_count = (register_count + WORD_MASK) >> WORD_SHIFT
        constants = Array.new(word_count, 0)
        defined = Array.new(word_count, 0)
        (function.parameter_count + function.local_count).times { |register| mark(defined, register) }
        function.constant_registers.each do |register|
          mark(constants, register)
          mark(defined, register)
        end
        blocks.fetch(0).merge(defined)
        pending = 1
        while pending > 0
          order.each do |block_index|
            break if pending == 0
            block = blocks.fetch(block_index)
            next unless block.pending

            block.pending = false
            pending -= 1
            defined = block.defined.dup
            pc = block.first
            while pc < block.limit
              instruction = instructions.fetch(pc)
              function.reads(instruction).each do |register|
                unless register >= 0 && register < register_count && marked?(defined, register)
                  raise TranslationError, "Efflorescence: function #{function.index}, MIR PC #{pc}: r#{register} read before definition"
                end
              end
              # A CALL result exists only on its normal successor.
              flow.exceptional.fetch(pc).each do |clause|
                edge_defined = defined.dup
                clause.destinations.each { |register| mark(edge_defined, register) }
                target = block_for_pc.fetch(clause.target_pc)
                pending += 1 if blocks.fetch(target).merge(edge_defined)
              end
              destination = Opcode.destination(instruction)
              if destination >= 0
                if destination >= register_count || marked?(constants, destination)
                  raise TranslationError, "Efflorescence: function #{function.index}, MIR PC #{pc}: invalid register destination r#{destination}"
                end
                mark(defined, destination)
              end
              pc += 1
            end
            flow.normal.fetch(block.limit - 1).each do |target_pc|
              target = block_for_pc.fetch(target_pc)
              pending += 1 if blocks.fetch(target).merge(defined)
            end
          end
        end
      end
      private

      # Visit predecessors before joins where possible, then revisit changed
      # states across backedges until the worklist is empty.
      # @rbs blocks: Array[Wardite::Efflorescence::RegisterValidation::Block]
      # @rbs block_for_pc: Array[Integer]
      # @rbs flow: Wardite::Efflorescence::FlowGraph
      # @rbs return: Array[Integer]
      def reverse_postorder(blocks, block_for_pc, flow)
        blocks.each do |block|
          flow.normal.fetch(block.limit - 1).each { |pc| block.successors << block_for_pc.fetch(pc) }
          (block.first...block.limit).each do |pc|
            flow.exceptional.fetch(pc).each { |clause| block.successors << block_for_pc.fetch(clause.target_pc) }
          end
        end

        seen = Array.new(blocks.size, false)
        next_edge = Array.new(blocks.size, 0)
        seen[0] = true
        stack = [0]
        postorder = [] #: Array[Integer]
        until stack.empty?
          index = stack.fetch(stack.size - 1)
          successors = blocks.fetch(index).successors
          edge = next_edge.fetch(index)
          if edge == successors.size
            postorder << index
            stack.pop
          else
            target = successors.fetch(edge)
            next_edge[index] = edge + 1
            unless seen.fetch(target)
              seen[target] = true
              stack << target
            end
          end
        end
        postorder.reverse
      end

      # @rbs words: Array[Integer]
      # @rbs register: Integer
      # @rbs return: void
      def mark(words, register)
        index = register >> WORD_SHIFT
        words[index] = words.fetch(index) | (1 << (register & WORD_MASK))
      end

      # @rbs words: Array[Integer]
      # @rbs register: Integer
      # @rbs return: bool
      def marked?(words, register)
        word = words.fetch(register >> WORD_SHIFT)
        (word & (1 << (register & WORD_MASK))) != 0
      end

      # Validate all registers, including unreachable instructions and table-only
      # operands. Numeric registers are checked before flat execution.
      # @rbs function: Wardite::Efflorescence::Function
      # @rbs return: void
      # @rbs ir: Wardite::Efflorescence::IR?
      # @rbs tags: Array[Wardite::Efflorescence::Tag]?
      def validate_types(function, ir, tags)
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
            if opcode == Opcode::CALL_HOST
              unless site.host_index >= 0 && site.table_index == -1 && instruction[3] == 0
                raise TranslationError, "invalid MIR host call operands"
              end
            elsif site.host_index != -1 || site.table_index != 0
              raise TranslationError, "invalid MIR indirect call operands"
            end
            unless site.arguments.size == site.parameter_types.size &&
                site.parameter_types.all? { |type| FunctionEntry.numeric_type?(type) } &&
                (site.result_types.empty? ? destination == -1 : site.result_types.size == 1 &&
                  FunctionEntry.numeric_type?(site.result_types.fetch(0)) && destination >= 0)
              raise TranslationError, "invalid MIR dynamic call signature"
            end
            if ir && opcode == Opcode::CALL_HOST
              host = ir.hosts[site.host_index]
              unless host && host.entry.parameter_types == site.parameter_types && host.entry.result_types == site.result_types
                raise TranslationError, "MIR host call signature mismatch"
              end
            end
            check_register(function, instruction[3], :i32) if opcode == Opcode::CALL_INDIRECT
            site.arguments.each_with_index { |register, i| check_register(function, register, site.parameter_types.fetch(i)) }
            check_result(function, destination, site.result_types)
            next
          end
          reads = function.reads(instruction)
          destination = Opcode.destination(instruction)
          if opcode > Opcode::CALL_INDIRECT
            validate_extended_instruction(function, instruction, reads, destination)
            next
          end
          case opcode
          when Opcode::THROW
            site = function.throw_sites.fetch(instruction[1])
            types = payload_types(tags, site.tag_index, reads.size)
            reads.each_with_index { |register, i| check_register(function, register, types.fetch(i)) }
          when Opcode::COPY
            type = function.register_types[destination] if destination >= 0
            unless type && FunctionEntry.numeric_type?(type)
              raise TranslationError, "invalid MIR numeric copy destination r#{destination}"
            end
            check_register(function, instruction[2], type)
          when Opcode::RETURN
            check_result(function, instruction[1], function.result_types)
          when Opcode::CALL
            if ir
              entry = ir.entry_at(instruction[2])
              unless entry.kind == :defined && reads.size == entry.parameter_types.size
                raise TranslationError, "invalid MIR direct call signature"
              end
              reads.each_with_index { |register, i| check_register(function, register, entry.parameter_types.fetch(i)) }
              check_result(function, destination, entry.result_types)
            else
              reads.each { |register| check_register(function, register, :i32) }
              check_register(function, destination, :i32) if destination >= 0
            end
          else
            expected = opcode == Opcode::COPY_REF || opcode == Opcode::THROW_REF ? :exnref : :i32
            reads.each { |register| check_register(function, register, expected) }
            check_register(function, destination, expected) if destination >= 0
          end
        end
        function.handlers.each do |handler|
          handler.clauses.each do |clause|
            types = payload_types(tags, clause.tag_index, clause.payload_registers.size)
            clause.payload_registers.each_with_index do |register, i|
              check_destination(function, register, types.fetch(i))
            end
            check_destination(function, clause.reference_register, :exnref) if clause.reference_register >= 0
          end
        end
      end

      # @rbs function: Wardite::Efflorescence::Function
      # @rbs instruction: Wardite::Efflorescence::Instruction
      # @rbs reads: Array[Integer]
      # @rbs destination: Integer
      # @rbs return: void
      def validate_extended_instruction(function, instruction, reads, destination)
        opcode = instruction[0]
        types = Opcode.extended_alu_types(opcode)
        if types
          check_register(function, destination, types.fetch(0))
          reads.each_with_index { |register, i| check_register(function, register, types.fetch(i + 1)) }
        elsif (type = Opcode::EXTENDED_LOAD_TYPES[opcode])
          check_register(function, destination, type)
          check_register(function, instruction[2], :i32)
        elsif (type = Opcode::EXTENDED_STORE_TYPES[opcode])
          check_register(function, instruction[1], type)
          check_register(function, instruction[2], :i32)
        elsif (type = Opcode::EXTENDED_GLOBAL_GET_TYPES[opcode])
          check_register(function, destination, type)
        elsif (type = Opcode::EXTENDED_GLOBAL_SET_TYPES[opcode])
          check_register(function, instruction[2], type)
        else
          raise TranslationError, "unknown extended MIR opcode #{opcode}"
        end
      end

      # @rbs tags: Array[Wardite::Efflorescence::Tag]?
      # @rbs index: Integer
      # @rbs size: Integer
      # @rbs return: Array[Symbol]
      def payload_types(tags, index, size)
        return Array.new(size, :i32) unless tags

        tag = tags[index] if index >= 0
        types = tag ? tag.parameter_types : [] #: Array[Symbol]
        if (index >= 0 && !tag) || size != types.size
          raise TranslationError, "invalid MIR exception payload"
        end
        types
      end

      # @rbs function: Wardite::Efflorescence::Function
      # @rbs register: Integer
      # @rbs types: Array[Symbol]
      # @rbs return: void
      def check_result(function, register, types)
        if types.empty?
          raise TranslationError, "invalid MIR void result" unless register == -1
        else
          check_register(function, register, types.fetch(0))
        end
      end

      # @rbs function: Wardite::Efflorescence::Function
      # @rbs register: Integer
      # @rbs type: Symbol
      # @rbs return: void
      def check_register(function, register, type)
        unless register >= 0 && function.register_types[register] == type
          raise TranslationError, "invalid MIR register type/index r#{register}"
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
