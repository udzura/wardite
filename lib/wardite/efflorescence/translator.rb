# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    # Only the translator has a Wasm operand stack. The VM sees register sources
    # and absolute MIR PCs, with no runtime labels or operand-stack unwinding.
    class Translator
      class Control
        attr_reader :kind #: Symbol
        attr_reader :entry_stack #: Array[Integer]
        attr_reader :start_pc #: Integer
        attr_reader :result_register #: Integer
        attr_reader :patches #: Array[Integer]
        attr_accessor :has_branch #: bool

        # @rbs kind: Symbol
        # @rbs entry_stack: Array[Integer]
        # @rbs start_pc: Integer
        # @rbs result_register: Integer
        def initialize(kind, entry_stack, start_pc, result_register)
          @kind = kind
          @entry_stack = entry_stack.dup
          @start_pc = start_pc
          @result_register = result_register
          @patches = []
          @has_branch = false
        end
      end

      # @rbs @instance: Wardite::Instance
      # @rbs @stack: Array[Integer]
      # @rbs @controls: Array[Wardite::Efflorescence::Translator::Control]
      # @rbs @constants: Hash[Integer, Integer]
      # @rbs @function: Wardite::Efflorescence::Function
      # @rbs @reachable: bool
      # @rbs @wasm_pc: Integer

      # @rbs instance: Wardite::Instance
      def initialize(instance)
        @instance = instance
        @stack = []
        @controls = []
        @constants = {}
        @reachable = true
        @wasm_pc = 0
        @function = Function.new(0, [], [], 0)
      end

      # @rbs return: Wardite::Efflorescence::IR
      def translate
        unless @instance.import_section.imports.empty?
          raise UnsupportedFeature, "Efflorescence: imports are not supported"
        end
        functions = [] #: Array[Wardite::Efflorescence::Function]
        @instance.store.funcs.each_with_index do |function, index|
          unless function.is_a?(Wardite::WasmFunction)
            raise UnsupportedFeature, "Efflorescence: host function #{index} is not supported"
          end
          functions << translate_function(function, index)
        end
        IR.new(functions)
      end

      # @rbs wasm: Wardite::WasmFunction
      # @rbs index: Integer
      # @rbs return: Wardite::Efflorescence::Function
      def translate_function(wasm, index)
        check_signature(wasm)
        unless wasm.locals_type.all? { |type| type == :i32 }
          raise UnsupportedFeature, "Efflorescence: function #{index} has non-i32 locals"
        end
        @function = Function.new(index, wasm.callsig, wasm.retsig, wasm.locals_count.sum)
        @stack = []
        @constants = {}
        @controls = []
        @reachable = true
        result = wasm.retsig.empty? ? -1 : register
        @controls << Control.new(:function, [], 0, result)

        wasm.body.each_with_index do |instruction, pc|
          @wasm_pc = pc
          fail_translation("instruction after function end") if @controls.empty?
          code = instruction[1]
          operands = instruction[2]
          case code
          when :block, :loop
            block = operands[0]
            unless block.is_a?(Wardite::Block) && (block.block_types.nil? || block.block_types == [0x7f])
              raise UnsupportedFeature, context("only void/i32 block results are supported")
            end
            # Freeze live local sources before the loop header. A backedge must
            # not re-read locals that were values on the stack before entry.
            snapshot_locals if @reachable
            output = block.result_size == 0 ? -1 : register
            @controls << Control.new(code, @stack, @function.instructions.size, output)
          when :end
            end_control
          when :local_get, :local_set, :local_tee
            local = integer_operand(operands[0])
            if local < 0 || local >= @function.parameter_count + @function.local_count
              fail_translation("invalid local index #{local}")
            end
            next unless @reachable
            if code == :local_get
              @stack << local
            else
              source = pop_value
              preserve_local(local)
              emit([Opcode::COPY, local, source]) unless local == source
              @stack << local if code == :local_tee
            end
          when :i32_const
            value = integer_operand(operands[0]) & 0xffffffff
            next unless @reachable
            slot = @constants[value]
            unless slot
              slot = @function.allocate_constant(value)
              @constants[value] = slot
            end
            @stack << slot
          when :i32_add, :i32_sub, :i32_mul, :i32_xor, :i32_shl, :i32_shr_u
            next unless @reachable
            right = pop_value
            left = pop_value
            dst = register
            emit([binary_opcode(code), dst, left, right])
            @stack << dst
          when :i32_eqz
            next unless @reachable
            source = pop_value
            dst = register
            emit([Opcode::I32_EQZ, dst, source])
            @stack << dst
          when :br, :br_if
            depth = integer_operand(operands[0])
            if depth < 0 || depth >= @controls.size
              fail_translation("invalid branch depth #{depth}")
            end
            next unless @reachable
            condition = code == :br_if ? pop_value : -1
            target = @controls[@controls.size - 1 - depth] || raise(TranslationError, "missing label")
            if target.kind != :loop && target.result_register >= 0
              source = peek_value
              emit([Opcode::COPY, target.result_register, source])
            end
            target_pc = target.kind == :loop ? target.start_pc : -1
            branch = condition < 0 ? [Opcode::BR, target_pc] : [Opcode::BR_IF, condition, target_pc]
            position = emit(branch)
            if target.kind != :loop
              target.patches << position
              target.has_branch = true
            end
            @reachable = false if code == :br
          when :call
            index = integer_operand(operands[0])
            fail_translation("invalid call target #{index}") if index < 0
            callee = @instance.store.funcs[index] || raise(TranslationError, context("invalid call target #{index}"))
            unless callee.is_a?(Wardite::WasmFunction)
              raise UnsupportedFeature, context("invalid or imported call target #{index}")
            end
            check_signature(callee)
            next unless @reachable
            arguments = [] #: Array[Integer]
            callee.callsig.size.times { arguments << pop_value }
            arguments.reverse!
            dst = callee.retsig.empty? ? -1 : register
            emit([Opcode::CALL, dst, index] + arguments)
            @stack << dst if dst >= 0
          when :return
            next unless @reachable
            source = @function.result_types.empty? ? -1 : pop_value
            emit([Opcode::RETURN, source])
            @reachable = false
          when :unreachable
            emit([Opcode::TRAP]) if @reachable
            @reachable = false
          when :drop
            pop_value if @reachable
          when :nop
            # No runtime instruction is necessary.
          else
            # Reject unsupported instructions even in unreachable code.
            raise UnsupportedFeature, context("unsupported instruction #{code}")
          end
        end
        fail_translation("missing function end") unless @controls.empty?
        @function
      end

      private

      # @rbs function: Wardite::WasmFunction
      # @rbs return: void
      def check_signature(function)
        unless function.callsig.all? { |type| type == :i32 } &&
            (function.retsig.empty? || function.retsig == [:i32])
          raise UnsupportedFeature, "Efflorescence: function #{function.findex} requires an i32-only signature with at most one result"
        end
      end

      # @rbs value: Wardite::operandItem?
      # @rbs return: Integer
      def integer_operand(value)
        fail_translation("expected integer operand") unless value.is_a?(Integer)
        value
      end

      # @rbs value: Integer
      # @rbs return: Integer
      def register(value = 0)
        @function.allocate_register(value)
      end

      # @rbs instruction: Array[Integer]
      # @rbs return: Integer
      def emit(instruction)
        position = @function.instructions.size
        @function.instructions << Instruction.new(instruction)
        position
      end

      # @rbs return: Integer
      def peek_value
        control = @controls.last || raise(TranslationError, "missing control")
        fail_translation("operand stack underflow") if @stack.size <= control.entry_stack.size
        @stack.last || raise(TranslationError, "missing operand")
      end

      # @rbs return: Integer
      def pop_value
        value = peek_value
        @stack.pop
        value
      end

      # @rbs local: Integer
      # @rbs return: void
      def preserve_local(local)
        return unless @stack.include?(local)
        snapshot = register
        emit([Opcode::COPY, snapshot, local])
        @stack.map! { |source| source == local ? snapshot : source }
      end

      # @rbs return: void
      def snapshot_locals
        @stack.dup.each do |source|
          preserve_local(source) if source < @function.parameter_count + @function.local_count
        end
      end

      # @rbs return: void
      def end_control
        control = @controls.last || raise(TranslationError, "unexpected end")
        if @reachable
          arity = control.result_register >= 0 ? 1 : 0
          unless @stack.size == control.entry_stack.size + arity
            fail_translation("incorrect stack height at end")
          end
          emit([Opcode::COPY, control.result_register, pop_value]) if arity == 1
        end
        @controls.pop
        target_pc = @function.instructions.size
        control.patches.each do |pc|
          instruction = @function.instructions[pc] || raise(TranslationError, "missing branch")
          instruction[instruction.size - 1] = target_pc
        end
        @stack = control.entry_stack.dup
        @stack << control.result_register if control.result_register >= 0
        @reachable = @reachable || control.has_branch
        emit([Opcode::RETURN, control.result_register]) if control.kind == :function
      end

      # @rbs code: Symbol
      # @rbs return: Integer
      def binary_opcode(code)
        case code
        when :i32_add then Opcode::I32_ADD
        when :i32_sub then Opcode::I32_SUB
        when :i32_mul then Opcode::I32_MUL
        when :i32_xor then Opcode::I32_XOR
        when :i32_shl then Opcode::I32_SHL
        when :i32_shr_u then Opcode::I32_SHR_U
        else raise UnsupportedFeature, context("unsupported instruction #{code}")
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
