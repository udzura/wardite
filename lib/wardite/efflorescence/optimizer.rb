# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    class Configuration
      FEATURES = %i[copy immediate branch superinstruction inline compact cse frames].freeze
      attr_reader :disabled #: Array[Symbol]

      # @rbs disabled: Array[Symbol]
      # @rbs enabled: Array[Symbol]
      # @rbs cse: bool
      def initialize(disabled, enabled: [], cse: false)
        unknown = (disabled + enabled) - FEATURES - [:all]
        raise Wardite::ArgumentError, "unknown MIR optimization: #{unknown.join(', ')}" unless unknown.empty?
        @disabled = disabled.include?(:all) ? FEATURES.dup : disabled.dup
        cse_enabled = cse || ENV["WARDITE_MIR_CSE"] == "1" || enabled.include?(:cse) || enabled.include?(:all)
        @disabled << :cse unless cse_enabled || @disabled.include?(:cse)
      end

      # @rbs feature: Symbol
      # @rbs return: bool
      def enabled?(feature)
        !@disabled.include?(feature)
      end
    end

    # Keep setup bounded for mixed functions. A larger call-free loop can
    # amortize preparation over repeated arithmetic and memory operations.
    class OptimizationScope
      SMALL_FUNCTION = 16
      SHORT_LOOP_FUNCTION = 128
      MAX_LOOP_FUNCTION = 1536
      LONG_LOOP = 64

      # @rbs function: Wardite::Efflorescence::Function
      # @rbs return: bool
      def self.caller?(function)
        return false if function.uses_eh
        return true unless function.uses_float || function.uses_i64 || function.uses_store || function.uses_dynamic_calls

        instructions = function.instructions
        return true if instructions.size <= SMALL_FUNCTION
        return false if instructions.size > MAX_LOOP_FUNCTION
        minimum = instructions.size <= SHORT_LOOP_FUNCTION ? 1 : LONG_LOOP
        call_free_loop?(instructions, minimum)
      end

      # @rbs instructions: Array[Instruction]
      # @rbs minimum: Integer
      # @rbs return: bool
      def self.call_free_loop?(instructions, minimum)
        after_call = 0
        instructions.each_with_index do |instruction, pc|
          opcode = instruction[0]
          if opcode == Opcode::CALL || Opcode.dynamic_call?(opcode)
            after_call = pc + 1
          else
            position = Opcode.target_position(instruction)
            if position >= 0
              target = instruction[position]
              return true if target >= after_call && pc - target + 1 >= minimum
            end
          end
        end
        false
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
          read_count = function.read_count(instruction)
          ordinal = 0
          while ordinal < read_count
            @reads[function.read_at(instruction, ordinal)] += 1
            ordinal += 1
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
      # Expand only small, straight-line leaves from pre-rewrite snapshots.
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
          callees = {} #: Hash[Integer, Wardite::Efflorescence::Function]
          ir.functions.each do |function|
            callees[function.index] = function.copy if eligible?(function)
          end
          changed = [] #: Array[Integer]
          index = 0
          while index < ir.functions.size
            function = ir.defined_at(index)
            changed << function.index if OptimizationScope.caller?(function) && expand_calls(function, ir, callees)
            index += 1
          end
          changed
        end

        # These bounds cannot improve during local optimization.
        # @rbs function: Wardite::Efflorescence::Function
        # @rbs return: bool
        def candidate?(function)
          function.register_count <= MAX_REGISTERS &&
            !(function.uses_i64 || function.uses_float || function.uses_eh || function.uses_store || function.uses_dynamic_calls)
        end

        # Explicit whitelist: new opcodes must opt into inlining. In particular,
        # traps, profiling records, control flow and nested calls stay intact.
        # @rbs function: Wardite::Efflorescence::Function
        # @rbs return: bool
        def eligible?(function)
          return false unless candidate?(function)
          instructions = function.instructions
          return false if instructions.empty? || instructions.size > MAX_INSTRUCTIONS
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
        # @rbs ir: Wardite::Efflorescence::IR
        # @rbs callees: Hash[Integer, Wardite::Efflorescence::Function]
        # @rbs return: bool
        def expand_calls(function, ir, callees)
          return false unless expandable_call?(function, ir, callees)

          rewrite = Rewrite.new(function)
          added_instructions = 0
          added_registers = 0
          changed = false
          function.instructions.each_with_index do |instruction, pc|
            rewrite.mark(pc)
            if instruction[0] == Opcode::CALL && (callee = callee_for(ir, callees, instruction))
              growth = instruction_growth(callee, instruction)
              registers = register_growth(callee)
              if added_instructions + growth <= MAX_ADDED_INSTRUCTIONS &&
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

        private

        # @rbs function: Wardite::Efflorescence::Function
        # @rbs ir: Wardite::Efflorescence::IR
        # @rbs callees: Hash[Integer, Wardite::Efflorescence::Function]
        # @rbs return: bool
        def expandable_call?(function, ir, callees)
          instructions = function.instructions
          pc = 0
          while pc < instructions.size
            instruction = instructions.fetch(pc)
            if instruction[0] == Opcode::CALL && (callee = callee_for(ir, callees, instruction))
              return true if instruction_growth(callee, instruction) <= MAX_ADDED_INSTRUCTIONS &&
                register_growth(callee) <= MAX_ADDED_REGISTERS
            end
            pc += 1
          end
          false
        end

        # Count the expansion before copy cleanup, conservatively.
        # @rbs callee: Wardite::Efflorescence::Function
        # @rbs call: Wardite::Efflorescence::Instruction
        # @rbs return: Integer
        def instruction_growth(callee, call)
          growth = callee.parameter_count + callee.local_count + callee.instructions.size - 2
          growth += 1 if call[1] >= 0
          growth < 0 ? 0 : growth
        end

        # @rbs callee: Wardite::Efflorescence::Function
        # @rbs return: Integer
        def register_growth(callee)
          callee.register_count + (callee.local_count > 0 ? 1 : 0)
        end

        # Check the module index even when there are no inline candidates.
        # @rbs ir: Wardite::Efflorescence::IR
        # @rbs callees: Hash[Integer, Wardite::Efflorescence::Function]
        # @rbs call: Wardite::Efflorescence::Instruction
        # @rbs return: Wardite::Efflorescence::Function?
        def callee_for(ir, callees, call)
          index = call[2]
          ir.function_at(index)
          callees[index]
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
        # @rbs coalesce_only: bool
        def run(function, coalesce_only: false)
          coalesce_results(function)
          return if coalesce_only

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
          instructions = function.instructions
          first_temp = function.parameter_count + function.local_count
          pc = 1
          while pc < instructions.size
            copy = instructions.fetch(pc)
            break if copy[0] == Opcode::COPY && copy[2] >= first_temp && Opcode.destination(instructions.fetch(pc - 1)) == copy[2]
            pc += 1
          end
          return if pc == instructions.size || instructions.empty?

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
              read_count = function.read_count(instruction)
              ordinal = 0
              while ordinal < read_count
                live[function.read_at(instruction, ordinal)] = 1
                ordinal += 1
              end
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

      class LocalCSE
        include Opcode

        # @rbs function: Function
        # @rbs return: void
        def run(function)
          analysis = Analysis.new(function)
          function.handlers.each do |handler|
            handler.clauses.each { |clause| analysis.leaders[clause.target_pc] = 1 }
          end
          values = {} #: Hash[Integer, Integer]
          expressions = {} #: Hash[String, Integer]
          holders = {} #: Hash[Integer, Integer]
          copies = [] #: Array[Integer]
          function.instructions.each_with_index do |insn, pc|
            if analysis.leaders[pc] == 1
              values.clear
              expressions.clear
              holders.clear
            end
            dest = Opcode.destination(insn)
            next if dest < 0
            # Entry slots have distinct negative numbers. Each definition can
            # introduce a new nonnegative number, including a trapping load.
            number = pc
            op = insn[0]
            if op == COPY
              number = values.fetch(insn[2], -1 - insn[2])
            elsif candidate?(op)
              key = expression(insn, values)
              previous = expressions.fetch(key, -1)
              if previous >= 0
                source = holders.fetch(previous)
                unless values.fetch(source) == previous
                  # A COPY may still hold the value after its producer changed.
                  source = values.key(previous) || -1
                end
                if source >= 0
                  number = previous
                  Opcode.read_positions(insn).each { |pos| analysis.reads[insn[pos]] -= 1 }
                  analysis.reads[source] += 1
                  function.instructions[pc] = Instruction.new([COPY, dest, source])
                  copies << pc
                end
              end
              expressions[key] = number
            end
            values[dest] = number
            holders[number] = dest
          end
          forward_copies(function, copies, analysis) unless copies.empty?
        end

        private

        # The opcode encodes both operand and result types. No store reads,
        # floating-point operations or trapping integer operations qualify.
        # @rbs op: Integer
        # @rbs return: bool
        def candidate?(op)
          op.between?(I32_ADD, I32_EQZ) || op.between?(I32_ADD_IMM, I32_SHR_U_IMM) ||
            op.between?(I32_EQ, I32_POPCNT) || op.between?(I32_AND, I32_EXTEND16_S) ||
            op.between?(I64_EQZ, I64_MUL)
        end

        # @rbs insn: Instruction
        # @rbs values: Hash[Integer, Integer]
        # @rbs return: String
        def expression(insn, values)
          op = insn[0]
          left = values.fetch(insn[2], -1 - insn[2])
          right = 0
          if insn.size > 3
            right = insn[3]
            unless op.between?(I32_ADD_IMM, I32_SHR_U_IMM)
              right = values.fetch(right, -1 - right)
              case op
              when I32_ADD, I32_MUL, I32_AND, I32_OR, I32_XOR, I32_EQ, I32_NE,
                   I64_ADD, I64_MUL, I64_AND, I64_OR, I64_XOR, I64_EQ, I64_NE
                left, right = right, left if left > right
              end
            end
          end
          "#{op}:#{left}:#{right}"
        end

        # Only forward copies introduced by CSE. Count all reads, including
        # side tables, before deleting a copy. Each alias expires on a write
        # to either slot or on entry to the next basic block.
        # @rbs function: Function
        # @rbs copies: Array[Integer]
        # @rbs analysis: Analysis
        # @rbs return: void
        def forward_copies(function, copies, analysis)
          reads = analysis.reads
          aliases = {} #: Hash[Integer, Integer]
          written = Array.new(function.register_count, -1)
          next_copy = 0
          function.instructions.each_with_index do |insn, pc|
            aliases.clear if analysis.leaders[pc] == 1
            unless aliases.empty?
              Opcode.read_positions(insn).each do |pos|
                slot = insn[pos]
                source = aliases.fetch(slot, -1)
                if source >= 0 && written[source] < written[slot]
                  insn[pos] = source
                  reads[slot] -= 1
                  reads[source] += 1
                end
              end
            end
            dest = Opcode.destination(insn)
            next if dest < 0
            written[dest] = pc
            aliases.delete(dest)
            if next_copy < copies.size && pc == copies.fetch(next_copy)
              aliases[dest] = insn[2]
              next_copy += 1
            end
          end
          rewrite = Rewrite.new(function)
          next_copy = 0
          function.instructions.each_with_index do |insn, pc|
            rewrite.mark(pc)
            if next_copy < copies.size && pc == copies.fetch(next_copy)
              next_copy += 1
              next if reads[insn[1]] == 0 || insn[1] == insn[2]
            end
            rewrite.emit(insn)
          end
          rewrite.finish
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
          instructions = function.instructions
          pc = 0
          while pc + 1 < instructions.size
            candidate = instructions.fetch(pc)
            break if instructions.fetch(pc + 1)[0] == Opcode::BR_IF && fused_branch(candidate[0]) >= 0
            pc += 1
          end
          return if pc + 1 >= instructions.size

          analysis = Analysis.new(function)
          rewrite = Rewrite.new(function)
          pc = 0
          while pc < function.instructions.size
            rewrite.mark(pc)
            instruction = function.instructions[pc]
            following = function.instructions[pc + 1]
            if following && following[0] == Opcode::BR_IF && fused_branch(instruction[0]) >= 0 &&
                following[1] == instruction[1] && analysis.single_use?(instruction[1]) &&
                instruction[1] >= function.parameter_count + function.local_count && analysis.leaders[pc + 1] == 0
              rewrite.mark(pc + 1)
              words = [fused_branch(instruction[0]), instruction[2], following[2]]
              words << instruction[3] unless instruction[0] == Opcode::I32_EQZ
              rewrite.emit(Instruction.new(words))
              pc += 2
            else
              rewrite.emit(instruction.copy)
              pc += 1
            end
          end
          rewrite.finish
        end

        private

        # @rbs opcode: Integer
        # @rbs return: Integer
        def fused_branch(opcode)
          case opcode
          when Opcode::I32_EQZ then Opcode::BR_IF_ZERO
          when Opcode::I64_EQ then Opcode::BR_IF_I64_EQ
          else -1
          end
        end
      end

      class Superinstructions
        # @rbs function: Wardite::Efflorescence::Function
        # @rbs return: void
        def run(function)
          instructions = function.instructions
          pc = 0
          while pc + 1 < instructions.size
            candidate = instructions.fetch(pc)
            break if candidate[0] == Opcode::I64_SHR_U && instructions.fetch(pc + 1)[0] == Opcode::I32_WRAP_I64
            break if (candidate[0] == Opcode::I32_SHR_U_IMM || candidate[0] == Opcode::I32_SHL_IMM) && instructions.fetch(pc + 1)[0] == Opcode::I32_XOR
            pc += 1
          end
          return if pc + 1 >= instructions.size

          analysis = Analysis.new(function)
          rewrite = Rewrite.new(function)
          pc = 0
          while pc < function.instructions.size
            rewrite.mark(pc)
            instruction = function.instructions[pc]
            following = function.instructions[pc + 1]
            if instruction[0] == Opcode::I64_SHR_U
              extract = masked_shift(function, analysis, pc)
              if extract
                rewrite.mark(pc + 1)
                rewrite.mark(pc + 2)
                rewrite.emit(extract)
                pc += 3
                next
              end
            end
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

        private

        # @rbs function: Function
        # @rbs analysis: Analysis
        # @rbs pc: Integer
        # @rbs return: Instruction?
        def masked_shift(function, analysis, pc)
          shift = function.instructions.fetch(pc)
          wrap = function.instructions[pc + 1]
          mask = function.instructions[pc + 2]
          return unless wrap && wrap[0] == Opcode::I32_WRAP_I64 && wrap[2] == shift[1]
          return unless mask && mask[0] == Opcode::I32_AND && mask[2] == wrap[1]
          return unless function.constant_registers.include?(shift[3]) && function.constant_registers.include?(mask[3])
          first_temp = function.parameter_count + function.local_count
          return unless shift[1] >= first_temp && wrap[1] >= first_temp
          return unless analysis.single_use?(shift[1]) && analysis.single_use?(wrap[1])
          return unless analysis.leaders[pc + 1] == 0 && analysis.leaders[pc + 2] == 0

          count = function.initial_value(shift[3]) & 63
          bits = function.initial_value(mask[3])
          # The interpreter shifts a signed carrier. Trim mask bits beyond the source's high bit.
          bits &= (1 << (64 - count)) - 1 if count > 32
          Instruction.new([Opcode::I32_EXTRACT_I64, mask[1], shift[2], (bits << 6) | count])
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
        optimize_in_place(ir.copy)
      end

      # @rbs output: Wardite::Efflorescence::IR
      # @rbs return: Wardite::Efflorescence::IR
      def optimize_in_place(output)
        output.functions.each do |function|
          optimize_function(function)
        end
        if @configuration.enabled?(:inline)
          Passes::Inlining.new.run(output).each do |index|
            optimize_function(output.function_at(index))
          end
        end
        output.functions.each { |function| compact_registers(function) }
        output
      end

      # @rbs function: Function
      # @rbs return: void
      def compact_registers(function)
        function.compact_registers! if @configuration.enabled?(:compact)
      end

      # @rbs function: Wardite::Efflorescence::Function
      # @rbs return: void
      def fuse_byte_sequences(function)
        ByteSequences.fuse(function) if function.uses_store && @configuration.enabled?(:superinstruction)
      end

      # @rbs function: Wardite::Efflorescence::Function
      # @rbs return: void
      def optimize_function(function)
        scoped = OptimizationScope.caller?(function)
        if @configuration.enabled?(:copy)
          if scoped
            mixed = function.uses_i64 || function.uses_float || function.uses_store || function.uses_dynamic_calls
            Passes::CopyPropagation.new.run(function, coalesce_only: mixed && function.instructions.size > OptimizationScope::SMALL_FUNCTION)
          elsif !function.uses_eh && function.instructions.size > OptimizationScope::MAX_LOOP_FUNCTION &&
              OptimizationScope.call_free_loop?(function.instructions, OptimizationScope::LONG_LOOP)
            Passes::CopyPropagation.new.run(function, coalesce_only: true)
          end
        end
        Passes::ImmediateSpecialization.new.run(function) if scoped && @configuration.enabled?(:immediate)
        Passes::LocalCSE.new.run(function) if @configuration.enabled?(:cse)
        return unless scoped

        Passes::BranchFusion.new.run(function) if @configuration.enabled?(:branch)
        Passes::Superinstructions.new.run(function) if @configuration.enabled?(:superinstruction)
      end
    end

    class Lowerer
      WIDTH = 4

      # @rbs ir: Wardite::Efflorescence::IR
      # @rbs return: void
      def compile(ir)
        ir.functions.each { |function| compile_function(function, ir) }
      end

      # @rbs function: Wardite::Efflorescence::Function
      # @rbs ir: Wardite::Efflorescence::IR
      # @rbs return: void
      def compile_function(function, ir)
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
      end
    end
  end
end
