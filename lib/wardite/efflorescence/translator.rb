# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    # The operand/control stacks exist only during translation. Execution uses
    # typed register banks, absolute PCs and explicit per-frame handler stacks.
    class Translator
      class Control
        attr_reader :kind #: Symbol
        attr_reader :entry_stack #: Array[Integer]
        attr_reader :start_pc #: Integer
        attr_reader :result_types #: Array[Symbol]
        attr_reader :result_registers #: Array[Integer]
        attr_reader :patches #: Array[Integer]
        attr_reader :catch_patches #: Array[Wardite::Efflorescence::CatchTarget]
        attr_reader :handler_depth #: Integer
        attr_reader :entry_reachable #: bool
        attr_accessor :has_branch #: bool
        attr_accessor :false_patch #: Integer
        attr_accessor :else_seen #: bool
        attr_accessor :then_reachable #: bool

        # @rbs kind: Symbol
        # @rbs entry_stack: Array[Integer]
        # @rbs start_pc: Integer
        # @rbs result_types: Array[Symbol]
        # @rbs result_registers: Array[Integer]
        # @rbs handler_depth: Integer
        # @rbs reachable: bool
        def initialize(kind, entry_stack, start_pc, result_types, result_registers, handler_depth, reachable)
          @kind, @entry_stack, @start_pc = kind, entry_stack.dup, start_pc
          @result_types, @result_registers = result_types, result_registers
          @handler_depth, @entry_reachable = handler_depth, reachable
          @patches, @catch_patches = [], []
          @has_branch, @else_seen, @then_reachable = false, false, false
          @false_patch = -1
        end
      end

      BINARY = {
        i32_add: Opcode::I32_ADD, i32_sub: Opcode::I32_SUB, i32_mul: Opcode::I32_MUL,
        i32_xor: Opcode::I32_XOR, i32_shl: Opcode::I32_SHL, i32_shr_u: Opcode::I32_SHR_U,
        i32_eq: Opcode::I32_EQ, i32_ne: Opcode::I32_NE, i32_lts: Opcode::I32_LTS,
        i32_ltu: Opcode::I32_LTU, i32_gts: Opcode::I32_GTS, i32_gtu: Opcode::I32_GTU,
        i32_les: Opcode::I32_LES, i32_leu: Opcode::I32_LEU, i32_ges: Opcode::I32_GES,
        i32_geu: Opcode::I32_GEU, i32_div_s: Opcode::I32_DIV_S, i32_div_u: Opcode::I32_DIV_U,
        i32_rem_s: Opcode::I32_REM_S, i32_rem_u: Opcode::I32_REM_U,
        i32_and: Opcode::I32_AND, i32_or: Opcode::I32_OR, i32_shr_s: Opcode::I32_SHR_S,
        i32_rotl: Opcode::I32_ROTL, i32_rotr: Opcode::I32_ROTR
      }.freeze
      UNARY = { i32_eqz: Opcode::I32_EQZ, i32_clz: Opcode::I32_CLZ,
                i32_ctz: Opcode::I32_CTZ, i32_popcnt: Opcode::I32_POPCNT,
                i32_extend8_s: Opcode::I32_EXTEND8_S, i32_extend16_s: Opcode::I32_EXTEND16_S }.freeze

      # Natural alignment exponents; alignment is a hint, not an address rule.
      MEMORY_WIDTHS = { i32_load: 2, i32_load8_s: 0, i32_load8_u: 0,
                        i32_load16_s: 1, i32_load16_u: 1,
                        i32_store: 2, i32_store8: 0, i32_store16: 1 }.freeze
      MEMORY_OPCODES = { i32_load: Opcode::I32_LOAD, i32_load8_s: Opcode::I32_LOAD8_S,
                         i32_load8_u: Opcode::I32_LOAD8_U, i32_load16_s: Opcode::I32_LOAD16_S,
                         i32_load16_u: Opcode::I32_LOAD16_U, i32_store: Opcode::I32_STORE,
                         i32_store8: Opcode::I32_STORE8, i32_store16: Opcode::I32_STORE16 }.freeze
      STORE_CODES = (MEMORY_WIDTHS.keys + %i[global_get global_set memory_size memory_grow memory_init memory_copy memory_fill]).freeze

      # @rbs @instance: Wardite::Instance
      # @rbs @stack: Array[Integer]
      # @rbs @controls: Array[Wardite::Efflorescence::Translator::Control]
      # @rbs @constants: Hash[Integer, Integer]
      # @rbs @function: Wardite::Efflorescence::Function
      # @rbs @reachable: bool
      # @rbs @wasm_pc: Integer
      # @rbs @handler_depth: Integer

      # @rbs instance: Wardite::Instance
      def initialize(instance)
        @instance = instance
        @stack, @controls, @constants = [], [], {}
        @reachable, @wasm_pc, @handler_depth = true, 0, 0
        @function = Function.new(0, [], [], 0)
      end

      # @rbs return: Wardite::Efflorescence::IR
      def translate
        raise UnsupportedFeature, "Efflorescence: imports are not supported" unless @instance.import_section.imports.empty?
        functions = [] #: Array[Wardite::Efflorescence::Function]
        @instance.store.funcs.each_with_index do |function, index|
          raise UnsupportedFeature, "Efflorescence: host functions are not supported" unless function.is_a?(Wardite::WasmFunction)
          functions << translate_function(function, index)
        end
        IR.new(functions)
      end

      # @rbs wasm: Wardite::WasmFunction
      # @rbs index: Integer
      # @rbs return: Wardite::Efflorescence::Function
      def translate_function(wasm, index)
        check_signature(wasm)
        unless wasm.locals_type.all? { |type| type == :i32 || type == :exnref }
          raise UnsupportedFeature, "Efflorescence: function #{index} has unsupported locals"
        end
        locals = [] #: Array[Symbol]
        wasm.locals_type.each_with_index { |type, i| wasm.locals_count.fetch(i).times { locals << type } }
        @function = Function.new(index, wasm.callsig, wasm.retsig, locals.size, local_types: locals)
        @stack, @controls, @constants = [], [], {}
        @reachable, @handler_depth = true, 0
        @controls << new_control(:function, wasm.retsig)
        wasm.body.each_with_index do |instruction, pc|
          @wasm_pc = pc
          fail_translation("instruction after function end") if @controls.empty?
          code, operands = instruction[1], instruction[2]
          validate_store_instruction(code, operands) if STORE_CODES.include?(code)
          if BINARY.key?(code)
            if @reachable
              right, left = pop_typed(:i32), pop_typed(:i32)
              dst = register
              emit([BINARY.fetch(code), dst, left, right])
              @stack << dst
            end
            next
          elsif UNARY.key?(code)
            if @reachable
              source = pop_typed(:i32)
              dst = register
              emit([UNARY.fetch(code), dst, source])
              @stack << dst
            end
            next
          end
          case code
          when :block, :loop, :if, :try_table
            block = operands[0]
            fail_translation("expected block signature") unless block.is_a?(Wardite::Block)
            unless block.parameter_types.empty? && block.result_types.all? { |type| type == :i32 || type == :exnref }
              raise UnsupportedFeature, context("block parameters and non-i32/exnref results are not supported")
            end
            condition = code == :if && @reachable ? pop_typed(:i32) : -1
            snapshot_locals if @reachable
            control = new_control(code, block.result_types)
            if code == :if && @reachable
              control.false_patch = emit([Opcode::BR_IF_ZERO, condition, -1])
            elsif code == :try_table
              @function.uses_eh = true
              clauses = operands[1]
              fail_translation("expected catch clauses") unless clauses.is_a?(Array)
              descriptor = make_handler(clauses)
              id = @function.handlers.size
              @function.handlers << descriptor
              emit([Opcode::EH_ENTER, id]) if @reachable
              @handler_depth += 1
            end
            @function.uses_eh = true if block.result_types.include?(:exnref)
            @controls << control
          when :else
            else_control
          when :end
            end_control
          when :i32_load, :i32_load8_s, :i32_load8_u, :i32_load16_s, :i32_load16_u,
               :i32_store, :i32_store8, :i32_store16
            next unless @reachable
            opcode = MEMORY_OPCODES.fetch(code)
            offset = integer_operand(operands[1])
            if code == :i32_store || code == :i32_store8 || code == :i32_store16
              value = pop_typed(:i32)
              address = pop_typed(:i32)
              emit([opcode, value, address, offset])
            else
              address = pop_typed(:i32)
              dst = register
              emit([opcode, dst, address, offset])
              @stack << dst
            end
          when :global_get, :global_set
            index = integer_operand(operands[0])
            next unless @reachable
            if code == :global_get
              dst = register
              emit([Opcode::GLOBAL_GET, dst, index])
              @stack << dst
            else
              emit([Opcode::GLOBAL_SET, index, pop_typed(:i32)])
            end
          when :local_get, :local_set, :local_tee
            local = integer_operand(operands[0])
            fail_translation("invalid local index #{local}") unless local >= 0 && local < @function.parameter_count + @function.local_count
            next unless @reachable
            if code == :local_get
              @stack << local
            else
              source = pop_typed(type_of(local))
              preserve_local(local)
              copy_value(local, source) unless local == source
              @stack << local if code == :local_tee
            end
          when :i32_const
            value = integer_operand(operands[0]) & 0xffffffff
            @stack << constant(value) if @reachable
          when :br, :br_if
            target = label(integer_operand(operands[0]))
            next unless @reachable
            condition = code == :br_if ? pop_typed(:i32) : -1
            types = label_types(target)
            sources = top_values(types)
            if code == :br_if && (types.size > 0 || @handler_depth != target.handler_depth)
              skip = emit([Opcode::BR_IF_ZERO, condition, -1])
              branch(target, sources)
              patch(skip, @function.instructions.size)
            else
              branch(target, sources, condition)
            end
            @reachable = false if code == :br
          when :br_table
            depths = operands[0]
            fail_translation("expected branch table") unless depths.is_a?(Array)
            targets = depths.map { |depth| label(depth) }
            default = label(integer_operand(operands[1]))
            types = label_types(default)
            fail_translation("inconsistent br_table label types") unless targets.all? { |target| label_types(target) == types }
            next unless @reachable
            selector = pop_typed(:i32)
            sources = top_values(types)
            targets.each_with_index do |target, i|
              comparison = register
              emit([Opcode::I32_EQ, comparison, selector, constant(i)])
              skip = emit([Opcode::BR_IF_ZERO, comparison, -1])
              branch(target, sources)
              patch(skip, @function.instructions.size)
            end
            branch(default, sources)
            @reachable = false
          when :select
            next unless @reachable
            condition, right, left = pop_typed(:i32), pop_typed(:i32), pop_typed(:i32)
            dst = register
            copy_value(dst, right)
            skip = emit([Opcode::BR_IF_ZERO, condition, -1])
            copy_value(dst, left)
            patch(skip, @function.instructions.size)
            @stack << dst
          when :call
            index = integer_operand(operands[0])
            fail_translation("invalid call target #{index}") if index < 0
            callee = @instance.store.funcs[index]
            fail_translation("invalid call target #{index}") unless callee.is_a?(Wardite::WasmFunction)
            check_signature(callee)
            next unless @reachable
            arguments = callee.callsig.reverse.map { |type| pop_typed(type) }.reverse
            dst = callee.retsig.empty? ? -1 : register
            emit([Opcode::CALL, dst, index] + arguments)
            @stack << dst if dst >= 0
          when :throw
            tag_index = integer_operand(operands[0])
            tag = tag_at(tag_index)
            @function.uses_eh = true
            next unless @reachable
            payload = tag.parameter_types.reverse.map { |type| pop_typed(type) }.reverse
            id = @function.throw_sites.size
            @function.throw_sites << ThrowSite.new(tag_index, payload)
            emit([Opcode::THROW, id])
            @reachable = false
          when :throw_ref
            @function.uses_eh = true
            emit([Opcode::THROW_REF, pop_typed(:exnref)]) if @reachable
            @reachable = false
          when :return
            next unless @reachable
            source = @function.result_types.empty? ? -1 : pop_typed(:i32)
            emit([Opcode::RETURN, source])
            @reachable = false
          when :unreachable
            emit([Opcode::TRAP]) if @reachable
            @reachable = false
          when :drop
            pop_value if @reachable
          when :nop
          else
            raise UnsupportedFeature, context("unsupported instruction #{code}")
          end
        end
        fail_translation("missing function end") unless @controls.empty?
        @function
      end

      private

      # Validate even dead instructions before deciding whether to emit MIR.
      # @rbs code: Symbol
      # @rbs operands: Array[Wardite::operandItem]
      # @rbs return: void
      def validate_store_instruction(code, operands)
        @function.uses_store = true
        if code == :global_get || code == :global_set
          index = integer_operand(operands[0])
          global = index >= 0 ? @instance.store.globals[index] : nil
          fail_translation("invalid global index #{index}") unless global
          unless global.type == :i32
            raise UnsupportedFeature, context("only i32 global access is supported")
          end
          fail_translation("global initializer type mismatch") unless global.value.is_a?(Wardite::I32)
          fail_translation("global.set on immutable global #{index}") if code == :global_set && !global.mutable
          return
        end
        fail_translation("memory instruction requires memory 0") if @instance.store.memories.empty?
        alignment = MEMORY_WIDTHS[code]
        if alignment
          hint = integer_operand(operands[0])
          offset = integer_operand(operands[1])
          fail_translation("invalid memory alignment") unless hint >= 0 && hint <= alignment
          fail_translation("invalid memory offset") unless offset >= 0 && offset <= 0xffffffff
        elsif code == :memory_init
          data_index = integer_operand(operands[0])
          fail_translation("memory.init requires data count") unless @instance.data_count_section
          count = @instance.data_section&.segments&.size || 0
          fail_translation("invalid data index #{data_index}") unless data_index >= 0 && data_index < count
          check_memory_index(integer_operand(operands[1]))
        elsif code == :memory_copy
          check_memory_index(integer_operand(operands[0]))
          check_memory_index(integer_operand(operands[1]))
        else
          check_memory_index(integer_operand(operands[0]))
        end
      end

      # @rbs index: Integer
      # @rbs return: void
      def check_memory_index(index)
        raise UnsupportedFeature, context("only memory 0 is supported") unless index == 0
      end

      # @rbs function: Wardite::WasmFunction
      # @rbs return: void
      def check_signature(function)
        unless function.callsig.all? { |type| type == :i32 } && (function.retsig.empty? || function.retsig == [:i32])
          raise UnsupportedFeature, "Efflorescence: function #{function.findex} requires an i32-only signature with at most one result"
        end
      end

      # @rbs value: Wardite::operandItem?
      # @rbs return: Integer
      def integer_operand(value)
        fail_translation("expected integer operand") unless value.is_a?(Integer)
        value
      end

      # @rbs type: Symbol
      # @rbs return: Integer
      def register(type = :i32)
        @function.allocate_register(0, type: type)
      end

      # @rbs value: Integer
      # @rbs return: Integer
      def constant(value)
        @constants[value] ||= @function.allocate_constant(value)
      end

      # @rbs kind: Symbol
      # @rbs types: Array[Symbol]
      # @rbs return: Wardite::Efflorescence::Translator::Control
      def new_control(kind, types)
        Control.new(kind, @stack, @function.instructions.size, types, types.map { |type| register(type) }, @handler_depth, @reachable)
      end

      # @rbs instruction: Array[Integer]
      # @rbs return: Integer
      def emit(instruction)
        position = @function.instructions.size
        @function.instructions << Instruction.new(instruction)
        position
      end

      # @rbs pc: Integer
      # @rbs target: Integer
      # @rbs return: void
      def patch(pc, target)
        instruction = @function.instructions.fetch(pc)
        instruction[instruction.size - 1] = target
      end

      # @rbs return: Integer
      def pop_value
        control = @controls.last || raise(TranslationError, "missing control")
        fail_translation("operand stack underflow") if @stack.size <= control.entry_stack.size
        @stack.pop || raise(TranslationError, "missing operand")
      end

      # @rbs register: Integer
      # @rbs return: Symbol
      def type_of(register)
        @function.register_types.fetch(register)
      end

      # @rbs type: Symbol
      # @rbs return: Integer
      def pop_typed(type)
        value = pop_value
        fail_translation("expected #{type}, got #{type_of(value)}") unless type_of(value) == type
        value
      end

      # @rbs destination: Integer
      # @rbs source: Integer
      # @rbs return: void
      def copy_value(destination, source)
        fail_translation("copy type mismatch") unless type_of(destination) == type_of(source)
        emit([type_of(source) == :exnref ? Opcode::COPY_REF : Opcode::COPY, destination, source])
      end

      # @rbs destinations: Array[Integer]
      # @rbs sources: Array[Integer]
      # @rbs return: void
      def parallel_copy(destinations, sources)
        if sources.size > 1
          sources = sources.map do |source|
            temp = register(type_of(source))
            copy_value(temp, source)
            temp
          end
        end
        destinations.each_with_index { |dst, i| copy_value(dst, sources.fetch(i)) }
      end

      # @rbs local: Integer
      # @rbs return: void
      def preserve_local(local)
        return unless @stack.include?(local)
        snapshot = register(type_of(local))
        copy_value(snapshot, local)
        @stack.map! { |source| source == local ? snapshot : source }
      end

      # @rbs return: void
      def snapshot_locals
        @stack.dup.each { |source| preserve_local(source) if source < @function.parameter_count + @function.local_count }
      end

      # @rbs depth: Integer
      # @rbs return: Wardite::Efflorescence::Translator::Control
      def label(depth)
        fail_translation("invalid branch depth #{depth}") unless depth >= 0 && depth < @controls.size
        @controls.fetch(@controls.size - 1 - depth)
      end

      # @rbs target: Wardite::Efflorescence::Translator::Control
      # @rbs return: Array[Symbol]
      def label_types(target)
        target.kind == :loop ? [] : target.result_types
      end

      # @rbs types: Array[Symbol]
      # @rbs return: Array[Integer]
      def top_values(types)
        control = @controls.last || raise(TranslationError, "missing control")
        fail_translation("operand stack underflow") if @stack.size < control.entry_stack.size + types.size
        values = @stack.last(types.size)
        fail_translation("branch result type mismatch") unless values.map { |value| type_of(value) } == types
        values
      end

      # @rbs target: Wardite::Efflorescence::Translator::Control
      # @rbs sources: Array[Integer]
      # @rbs condition: Integer
      # @rbs return: void
      def branch(target, sources, condition = -1)
        parallel_copy(target.result_registers, sources) unless target.kind == :loop
        emit([Opcode::EH_TRIM, target.handler_depth]) if @handler_depth != target.handler_depth
        pc = target.kind == :loop ? target.start_pc : -1
        position = emit(condition < 0 ? [Opcode::BR, pc] : [Opcode::BR_IF, condition, pc])
        unless target.kind == :loop
          target.patches << position
          target.has_branch = true
        end
      end

      # @rbs index: Integer
      # @rbs return: Wardite::Efflorescence::Tag
      def tag_at(index)
        fail_translation("invalid tag index #{index}") if index < 0
        @instance.tags[index] || raise(TranslationError, context("invalid tag index #{index}"))
      end

      # Catch labels resolve before pushing the try_table's own label.
      # @rbs clauses: Array[Integer]
      # @rbs return: Wardite::Efflorescence::HandlerDescriptor
      def make_handler(clauses)
        targets = [] #: Array[Wardite::Efflorescence::CatchTarget]
        clauses.each_slice(3) do |clause|
          kind, tag_index, depth = clause.fetch(0), clause.fetch(1), clause.fetch(2)
          target = label(depth)
          types = kind <= 1 ? tag_at(tag_index).parameter_types.dup : [] #: Array[Symbol]
          reference = kind == 1 || kind == 3
          types << :exnref if reference
          fail_translation("catch payload/label type mismatch") unless types == label_types(target)
          destinations = target.kind == :loop ? [] : target.result_registers.dup #: Array[Integer]
          ref = reference ? (destinations.pop || raise(TranslationError, "missing reference result")) : -1
          entry = CatchTarget.new(tag_index, destinations, ref, target.kind == :loop ? target.start_pc : -1, target.handler_depth)
          if target.kind != :loop
            target.catch_patches << entry
            target.has_branch = true if @reachable
          end
          targets << entry
        end
        HandlerDescriptor.new(targets)
      end

      # @rbs control: Wardite::Efflorescence::Translator::Control
      # @rbs return: void
      def finish_arm(control)
        return unless @reachable
        fail_translation("incorrect stack height at end") unless @stack.size == control.entry_stack.size + control.result_types.size
        parallel_copy(control.result_registers, top_values(control.result_types))
      end

      # @rbs return: void
      def else_control
        control = @controls.last || raise(TranslationError, "unexpected else")
        fail_translation("unexpected else") unless control.kind == :if && !control.else_seen
        finish_arm(control)
        control.then_reachable = @reachable
        control.patches << emit([Opcode::BR, -1]) if @reachable
        patch(control.false_patch, @function.instructions.size) if control.false_patch >= 0
        control.else_seen = true
        @stack = control.entry_stack.dup
        @reachable = control.entry_reachable
      end

      # @rbs return: void
      def end_control
        control = @controls.last || raise(TranslationError, "unexpected end")
        finish_arm(control)
        if control.kind == :try_table
          @handler_depth = control.handler_depth
          emit([Opcode::EH_TRIM, @handler_depth]) if @reachable
        end
        if control.kind == :if && !control.else_seen
          fail_translation("result-bearing if requires else") unless control.result_types.empty?
          patch(control.false_patch, @function.instructions.size) if control.false_patch >= 0
          @reachable ||= control.entry_reachable
        end
        @controls.pop
        pc = @function.instructions.size
        control.patches.each { |position| patch(position, pc) }
        control.catch_patches.each { |entry| entry.target_pc = pc }
        @stack = control.entry_stack.dup + control.result_registers
        @reachable = @reachable || control.has_branch || control.then_reachable
        if control.kind == :function
          emit([Opcode::RETURN, control.result_registers.empty? ? -1 : control.result_registers.fetch(0)])
        end
      end

      # @rbs message: String
      # @rbs return: String
      def context(message)
        "Efflorescence: function #{@function.index}, Wasm PC #{@wasm_pc}: #{message}"
      end

      # @rbs message: String
      # @rbs return: bot
      def fail_translation(message)
        raise TranslationError, context(message)
      end
    end
  end
end
