# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    class Configuration
      FEATURES = %i[copy immediate branch superinstruction inline frames].freeze
      attr_reader :disabled #: Array[Symbol]

      # @rbs disabled: Array[Symbol]
      def initialize(disabled)
        unknown = disabled - FEATURES - [:all]
        raise Wardite::ArgumentError, "unknown MIR optimization: #{unknown.join(', ')}" unless unknown.empty?
        @disabled = disabled.include?(:all) ? FEATURES.dup : disabled.dup
      end

      # @rbs feature: Symbol
      # @rbs return: bool
      def enabled?(feature)
        !@disabled.include?(feature)
      end
    end

    # All transformations use instruction ordinals. Only the final lowering
    # changes PCs to integer-array offsets. Every rewrite repairs branch edges.
    class Rewrite
      # @rbs function: Wardite::Efflorescence::Function
      def initialize(function)
        @function = function
        @mapping = Array.new(function.instructions.size + 1, 0)
        @output = [] #: Array[Wardite::Efflorescence::Instruction]
      end

      # @rbs pc: Integer
      # @rbs return: void
      def mark(pc)
        @mapping[pc] = @output.size
      end

      # @rbs instruction: Wardite::Efflorescence::Instruction
      # @rbs return: void
      def emit(instruction)
        @output << instruction
      end

      # @rbs return: void
      def finish
        @mapping[@function.instructions.size] = @output.size
        @function.replace_instructions(@output)
        @function.remap_targets!(@mapping)
      end
    end

    # A shared CFG includes exceptional edges with their edge-local writes.
    # Handler shapes are checked independently of definite assignment.
    class FlowGraph
      attr_reader :normal #: Array[Array[Integer]]
      attr_reader :exceptional #: Array[Array[Wardite::Efflorescence::CatchTarget]]

      # @rbs function: Wardite::Efflorescence::Function
      def initialize(function)
        count = function.instructions.size
        @normal = Array.new(count) { [] }
        @exceptional = Array.new(count) { [] }
        @states = Array.new(count) { [] } #: Array[Array[Integer]]
        @reached = Array.new(count, false)
        @pending = [] #: Array[Integer]
        function.instructions.each_with_index do |instruction, pc|
          position = Opcode.target_position(instruction)
          if position >= 0
            target = instruction[position]
            raise TranslationError, "invalid MIR branch target #{target}" unless target >= 0 && target < count
            @normal.fetch(pc) << target
          end
          @normal.fetch(pc) << pc + 1 unless Opcode.terminal?(instruction[0]) || pc + 1 == count
        end
        function.handlers.each do |handler|
          handler.clauses.each do |clause|
            raise TranslationError, "invalid catch target PC" unless clause.target_pc >= 0 && clause.target_pc < count
          end
        end
        merge(0, []) unless count == 0
        until @pending.empty?
          pc = @pending.pop || raise(TranslationError, "missing CFG node")
          instruction = function.instructions.fetch(pc)
          stack = @states.fetch(pc).dup
          if Opcode.may_throw?(instruction[0])
            stack.each_with_index do |id, depth|
              function.handlers.fetch(id).clauses.each do |clause|
                unless clause.handler_depth >= 0 && clause.handler_depth <= depth
                  raise TranslationError, "catch target retains a removed handler"
                end
                @exceptional.fetch(pc) << clause unless @exceptional.fetch(pc).include?(clause)
                merge(clause.target_pc, stack.take(clause.handler_depth))
              end
            end
          end
          if instruction[0] == Opcode::EH_ENTER
            id = instruction[1]
            raise TranslationError, "invalid handler descriptor" unless id >= 0 && id < function.handlers.size
            stack << id
          elsif instruction[0] == Opcode::EH_TRIM
            depth = instruction[1]
            raise TranslationError, "invalid handler trim" unless depth >= 0 && depth <= stack.size
            stack = stack.take(depth)
          end
          if @normal.fetch(pc).empty? && !Opcode.terminal?(instruction[0])
            raise TranslationError, "MIR falls through without RETURN"
          end
          @normal.fetch(pc).each { |target| merge(target, stack) }
        end
      end

      private

      # @rbs pc: Integer
      # @rbs stack: Array[Integer]
      # @rbs return: void
      def merge(pc, stack)
        if @reached.fetch(pc)
          raise TranslationError, "inconsistent handler stack at MIR PC #{pc}" unless @states.fetch(pc) == stack
        else
          @states[pc] = stack.dup
          @reached[pc] = true
          @pending << pc
        end
      end
    end

    class Analysis
      # @rbs @flow: Wardite::Efflorescence::FlowGraph?
      attr_reader :leaders #: Array[Integer]
      attr_reader :reads #: Array[Integer]
      attr_reader :writes #: Array[Integer]

      # @rbs function: Wardite::Efflorescence::Function
      def initialize(function)
        @function = function
        @flow = function.uses_eh || !function.handlers.empty? ? FlowGraph.new(function) : nil
        @leaders = Array.new(function.instructions.size, 0)
        @leaders[0] = 1 unless @leaders.empty?
        @reads = Array.new(function.register_count, 0)
        @writes = Array.new(function.register_count, 0)
        function.instructions.each_with_index do |instruction, pc|
          function.reads(instruction).each do |register|
            @reads[register] += 1
          end
          destination = Opcode.destination(instruction)
          @writes[destination] += 1 if destination >= 0
          target = Opcode.target_position(instruction)
          if target >= 0
            destination_pc = instruction[target]
            unless destination_pc >= 0 && destination_pc < function.instructions.size
              raise TranslationError, "Efflorescence: invalid MIR branch target #{destination_pc}"
            end
            @leaders[destination_pc] = 1
          end
          exceptional = @flow ? @flow.exceptional.fetch(pc) : [] #: Array[Wardite::Efflorescence::CatchTarget]
          exceptional.each { |clause| @leaders[clause.target_pc] = 1 }
          if target >= 0 || Opcode.terminal?(instruction[0]) || !exceptional.empty?
            @leaders[pc + 1] = 1 if pc + 1 < @leaders.size
          end
        end
      end

      # Ordinary optimization passes need only the summary above. Build the full
      # normal CFG once for validation; EH summaries also need it for leaders.
      # @rbs return: Wardite::Efflorescence::FlowGraph
      def flow
        @flow ||= FlowGraph.new(@function)
      end

      # @rbs register: Integer
      # @rbs return: bool
      def single_use?(register)
        register >= 0 && @reads[register] == 1 && @writes[register] == 1
      end
    end

    module Passes
      # Expand only small, straight-line leaves from a snapshot of the IR.
      # One round avoids transitive/exponential expansion and keeps recursion
      # on the ordinary CALL path. Existing local passes clean up the copies.
      class Inlining
        MAX_INSTRUCTIONS = 8
        MAX_REGISTERS = 32
        MAX_ADDED_INSTRUCTIONS = 64
        MAX_ADDED_REGISTERS = 256

        # @rbs ir: Wardite::Efflorescence::IR
        # @rbs return: Array[Integer]
        def run(ir)
          callees = ir.copy
          changed = [] #: Array[Integer]
          index = 0
          while index < ir.functions.size
            function = ir.defined_at(index)
            changed << function.index if !function.uses_eh && !function.uses_store && expand_calls(function, callees)
            index += 1
          end
          changed
        end

        private

        # Explicit whitelist: new opcodes must opt into inlining. In particular,
        # traps, profiling records, control flow and nested calls stay intact.
        # @rbs function: Wardite::Efflorescence::Function
        # @rbs return: bool
        def eligible?(function)
          return false if function.uses_eh || function.uses_store
          instructions = function.instructions
          return false if instructions.empty? || instructions.size > MAX_INSTRUCTIONS || function.register_count > MAX_REGISTERS
          return false unless instructions.last[0] == Opcode::RETURN
          index = 0
          while index < instructions.size - 1
            opcode = instructions[index][0]
            return false unless (opcode >= Opcode::COPY && opcode <= Opcode::I32_EQZ) ||
              (opcode >= Opcode::I32_ADD_IMM && opcode <= Opcode::I32_SHR_U_IMM) ||
              opcode == Opcode::I32_XOR_SHR_U_IMM || opcode == Opcode::I32_XOR_SHL_IMM
            index += 1
          end
          true
        end

        # @rbs function: Wardite::Efflorescence::Function
        # @rbs callees: Wardite::Efflorescence::IR
        # @rbs return: bool
        def expand_calls(function, callees)
          rewrite = Rewrite.new(function)
          added_instructions = 0
          added_registers = 0
          changed = false
          function.instructions.each_with_index do |instruction, pc|
            rewrite.mark(pc)
            if instruction[0] == Opcode::CALL
              callee = callees.function_at(instruction[2])
              # Count the expansion before copy cleanup, conservatively.
              growth = callee.parameter_count + callee.local_count + callee.instructions.size - 2
              growth += 1 if instruction[1] >= 0
              growth = 0 if growth < 0
              registers = callee.register_count + (callee.local_count > 0 ? 1 : 0)
              if eligible?(callee) && added_instructions + growth <= MAX_ADDED_INSTRUCTIONS &&
                  added_registers + registers <= MAX_ADDED_REGISTERS
                expand(function, callee, instruction, rewrite)
                added_instructions += growth
                added_registers += registers
                changed = true
                next
              end
            end
            rewrite.emit(instruction.copy)
          end
          rewrite.finish
          changed
        end

        # @rbs caller: Wardite::Efflorescence::Function
        # @rbs callee: Wardite::Efflorescence::Function
        # @rbs call: Wardite::Efflorescence::Instruction
        # @rbs rewrite: Wardite::Efflorescence::Rewrite
        # @rbs return: void
        def expand(caller, callee, call, rewrite)
          registers = [] #: Array[Integer]
          index = 0
          while index < callee.register_count
            registers << if callee.constant_registers.include?(index)
              caller.allocate_constant(callee.initial_value(index))
            else
              caller.allocate_register(0)
            end
            index += 1
          end
          # Fresh slots preserve argument snapshots even if the callee mutates
          # a parameter, or the CALL destination aliases a caller argument.
          index = 0
          while index < callee.parameter_count
            rewrite.emit(Instruction.new([Opcode::COPY, registers.fetch(index), call[3 + index]]))
            index += 1
          end
          if callee.local_count > 0
            zero = caller.allocate_constant(0)
            while index < callee.parameter_count + callee.local_count
              rewrite.emit(Instruction.new([Opcode::COPY, registers.fetch(index), zero]))
              index += 1
            end
          end
          callee.instructions.each do |original|
            if original[0] == Opcode::RETURN
              if call[1] >= 0
                rewrite.emit(Instruction.new([Opcode::COPY, call[1], registers.fetch(original[1])]))
              end
            else
              instruction = original.copy
              Opcode.read_positions(original).each do |position|
                instruction[position] = registers.fetch(original[position])
              end
              destination = Opcode.destination(original)
              instruction[1] = registers.fetch(destination) if destination >= 0
              rewrite.emit(instruction)
            end
          end
        end
      end

      class CopyPropagation
        # @rbs function: Wardite::Efflorescence::Function
        # @rbs return: void
        def run(function)
          coalesce_results(function)
          propagate(function)
          remove_overwritten_copies(function)
          remove_dead_copies(function)
        end

        private

        # Redirect an adjacent producer into the COPY destination. The producer
        # temporary has one definition and one use in the entire function, and
        # nobody can enter at the COPY. No value is moved across another op.
        # @rbs function: Wardite::Efflorescence::Function
        # @rbs return: void
        def coalesce_results(function)
          analysis = Analysis.new(function)
          rewrite = Rewrite.new(function)
          pc = 0
          while pc < function.instructions.size
            rewrite.mark(pc)
            instruction = function.instructions[pc].copy
            following = function.instructions[pc + 1]
            destination = Opcode.destination(instruction)
            if following && following[0] == Opcode::COPY && destination >= function.parameter_count + function.local_count &&
                analysis.single_use?(destination) && following[2] == destination && analysis.leaders[pc + 1] == 0
              instruction[1] = following[1]
              rewrite.mark(pc + 1)
              pc += 1
            end
            rewrite.emit(instruction)
            pc += 1
          end
          rewrite.finish
        end

        # @rbs function: Wardite::Efflorescence::Function
        # @rbs return: void
        def propagate(function)
          analysis = Analysis.new(function)
          aliases = (0...function.register_count).to_a
          rewrite = Rewrite.new(function)
          function.instructions.each_with_index do |original, pc|
            rewrite.mark(pc)
            aliases = (0...function.register_count).to_a if analysis.leaders[pc] == 1
            instruction = original.copy
            Opcode.read_positions(instruction).each do |position|
              instruction[position] = aliases.fetch(instruction[position])
            end
            destination = Opcode.destination(instruction)
            if destination >= 0
              aliases.each_with_index do |source, register|
                aliases[register] = register if source == destination || register == destination
              end
              if instruction[0] == Opcode::COPY && instruction[2] != destination
                aliases[destination] = instruction[2]
              end
            end
            rewrite.emit(instruction)
          end
          rewrite.finish
        end

        # Backward liveness inside each basic block removes copies overwritten
        # before any read (e.g. an inlined parameter initializer). All registers
        # are conservatively live across edges; no value moves across a branch.
        # @rbs function: Wardite::Efflorescence::Function
        # @rbs return: void
        def remove_overwritten_copies(function)
          analysis = Analysis.new(function)
          live = Array.new(function.register_count, 1)
          removed = Array.new(function.instructions.size, 0)
          pc = function.instructions.size - 1
          while pc >= 0
            live.fill(1) if pc + 1 < analysis.leaders.size && analysis.leaders[pc + 1] == 1
            instruction = function.instructions[pc]
            destination = Opcode.destination(instruction)
            if instruction[0] == Opcode::COPY && live[destination] == 0
              removed[pc] = 1
            else
              live[destination] = 0 if destination >= 0
              Opcode.read_positions(instruction).each { |position| live[instruction[position]] = 1 }
            end
            pc -= 1
          end
          rewrite = Rewrite.new(function)
          function.instructions.each_with_index do |instruction, index|
            rewrite.mark(index)
            rewrite.emit(instruction.copy) if removed[index] == 0
          end
          rewrite.finish
        end

        # Keep snapshot and join copies unless their destination has no reads
        # anywhere. Iteration also removes copies feeding another dead copy.
        # @rbs function: Wardite::Efflorescence::Function
        # @rbs return: void
        def remove_dead_copies(function)
          loop do
            analysis = Analysis.new(function)
            rewrite = Rewrite.new(function)
            changed = false
            function.instructions.each_with_index do |instruction, pc|
              rewrite.mark(pc)
              if instruction[0] == Opcode::COPY && (instruction[1] == instruction[2] || analysis.reads[instruction[1]] == 0)
                changed = true
              else
                rewrite.emit(instruction.copy)
              end
            end
            rewrite.finish
            break unless changed
          end
        end
      end

      class ImmediateSpecialization
        # @rbs function: Wardite::Efflorescence::Function
        # @rbs return: void
        def run(function)
          function.instructions.each do |instruction|
            opcode = instruction[0]
            next unless opcode >= Opcode::I32_ADD && opcode <= Opcode::I32_SHR_U
            left = instruction[2]
            right = instruction[3]
            if !function.constant_registers.include?(right) && function.constant_registers.include?(left) &&
                (opcode == Opcode::I32_ADD || opcode == Opcode::I32_MUL || opcode == Opcode::I32_XOR)
              left, right = right, left
            end
            next unless function.constant_registers.include?(right)
            instruction[0] = Opcode::I32_ADD_IMM + opcode - Opcode::I32_ADD
            instruction[2] = left
            instruction[3] = function.initial_value(right)
          end
        end
      end

      class BranchFusion
        # @rbs function: Wardite::Efflorescence::Function
        # @rbs return: void
        def run(function)
          analysis = Analysis.new(function)
          rewrite = Rewrite.new(function)
          pc = 0
          while pc < function.instructions.size
            rewrite.mark(pc)
            instruction = function.instructions[pc]
            following = function.instructions[pc + 1]
            if instruction[0] == Opcode::I32_EQZ && following && following[0] == Opcode::BR_IF &&
                following[1] == instruction[1] && analysis.single_use?(instruction[1]) &&
                instruction[1] >= function.parameter_count + function.local_count && analysis.leaders[pc + 1] == 0
              rewrite.mark(pc + 1)
              rewrite.emit(Instruction.new([Opcode::BR_IF_ZERO, instruction[2], following[2]]))
              pc += 2
            else
              rewrite.emit(instruction.copy)
              pc += 1
            end
          end
          rewrite.finish
        end
      end

      class Superinstructions
        # @rbs function: Wardite::Efflorescence::Function
        # @rbs return: void
        def run(function)
          analysis = Analysis.new(function)
          rewrite = Rewrite.new(function)
          pc = 0
          while pc < function.instructions.size
            rewrite.mark(pc)
            instruction = function.instructions[pc]
            following = function.instructions[pc + 1]
            shift = instruction[0] == Opcode::I32_SHR_U_IMM || instruction[0] == Opcode::I32_SHL_IMM
            if shift && following && following[0] == Opcode::I32_XOR && analysis.leaders[pc + 1] == 0 &&
                instruction[1] >= function.parameter_count + function.local_count && analysis.single_use?(instruction[1]) &&
                ((following[2] == instruction[2] && following[3] == instruction[1]) ||
                 (following[3] == instruction[2] && following[2] == instruction[1]))
              opcode = instruction[0] == Opcode::I32_SHR_U_IMM ? Opcode::I32_XOR_SHR_U_IMM : Opcode::I32_XOR_SHL_IMM
              rewrite.mark(pc + 1)
              rewrite.emit(Instruction.new([opcode, following[1], instruction[2], instruction[3] & 31]))
              pc += 2
            else
              rewrite.emit(instruction.copy)
              pc += 1
            end
          end
          rewrite.finish
        end
      end
    end

    class Optimizer
      # @rbs configuration: Wardite::Efflorescence::Configuration
      def initialize(configuration)
        @configuration = configuration
      end

      # Never mutate the translator's semantic MIR; retain it for inspection
      # and differential execution. Each pass can also be run independently.
      # @rbs ir: Wardite::Efflorescence::IR
      # @rbs return: Wardite::Efflorescence::IR
      def optimize(ir)
        output = ir.copy
        output.functions.each do |function|
          optimize_function(function)
        end
        if @configuration.enabled?(:inline)
          Passes::Inlining.new.run(output).each do |index|
            optimize_function(output.function_at(index))
          end
        end
        output
      end

      private

      # @rbs function: Wardite::Efflorescence::Function
      # @rbs return: void
      def optimize_function(function)
        return if function.uses_eh || function.uses_store
        Passes::CopyPropagation.new.run(function) if @configuration.enabled?(:copy)
        Passes::ImmediateSpecialization.new.run(function) if @configuration.enabled?(:immediate)
        Passes::BranchFusion.new.run(function) if @configuration.enabled?(:branch)
        Passes::Superinstructions.new.run(function) if @configuration.enabled?(:superinstruction)
      end
    end

    class Lowerer
      WIDTH = 4

      # @rbs ir: Wardite::Efflorescence::IR
      # @rbs return: void
      def compile(ir)
        function_index = 0
        while function_index < ir.functions.size
          function = ir.defined_at(function_index)
          code = [] #: Array[Integer]
          calls = [] #: Array[Wardite::Efflorescence::CallSite]
          function.instructions.each do |instruction|
            opcode = instruction[0]
            a = instruction.size > 1 ? instruction[1] : 0
            b = instruction.size > 2 ? instruction[2] : 0
            c = instruction.size > 3 ? instruction[3] : 0
            if opcode == Opcode::CALL
              callee = ir.function_at(instruction[2])
              arguments = [] #: Array[Integer]
              index = 3
              while index < instruction.size
                arguments << instruction[index]
                index += 1
              end
              b = calls.size
              # The fourth slot is already decoded on every dispatch. A single
              # argument can name its source here, bypassing the argument table
              # and loop; -1 selects the generic zero/multiple-argument path.
              c = arguments.size == 1 ? arguments.fetch(0) : -1
              calls << CallSite.new(callee, arguments)
            end
            target_position = Opcode.target_position(instruction)
            a *= WIDTH if target_position == 1
            b *= WIDTH if target_position == 2
            code << opcode << a << b << c
          end
          function.lower_handlers
          function.install_code(code, calls)
          function_index += 1
        end
      end
    end
  end
end
