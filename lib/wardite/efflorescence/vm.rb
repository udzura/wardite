# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    class VM
      attr_reader :instance #: Wardite::Instance
      attr_reader :ir #: Wardite::Efflorescence::IR

      # @rbs instance: Wardite::Instance
      def initialize(instance)
        @instance = instance
        @ir = Translator.new(instance).translate
        start = instance.start_section
        execute(start.func_index, []) if start
      end

      # @rbs name: String|Symbol
      # @rbs return: bool
      def callable?(name)
        export = @instance.export_section.exports[name.to_s]
        !!export && export.kind == 0
      end

      # Compatible with Runtime.call: boxing happens once, at the Ruby boundary.
      # @rbs name: String|Symbol
      # @rbs arguments: Array[Object]
      # @rbs return: Wardite::I32?
      def call(name, arguments)
        result = call_unboxed(name, arguments)
        result.nil? ? nil : Wardite::I32.new(result)
      end

      # @rbs name: String|Symbol
      # @rbs arguments: Array[Object]
      # @rbs return: Integer?
      def call_unboxed(name, arguments)
        export = @instance.export_section.exports[name.to_s]
        raise ::NoMethodError, "function #{name} not found" unless export
        raise ::NoMethodError, "#{name} is not a function" unless export.kind == 0
        function = @ir.functions[export.index] || raise(Wardite::EvalError, "invalid function index")
        unless arguments.size == function.parameter_count
          raise Wardite::ArgumentError, "unmatch arg size"
        end
        values = [] #: Array[Integer]
        arguments.each do |value|
          raise Wardite::ArgumentError, "type mismatch: i32(#{value})" unless value.is_a?(Integer)
          values << (value & 0xffffffff)
        end
        result = execute(export.index, values)
        function.result_types.empty? ? nil : result
      end

      # @rbs name: Symbol
      # @rbs *arguments: Object
      # @rbs return: Wardite::I32?
      def method_missing(name, *arguments)
        callable?(name) ? call(name, arguments) : super
      end

      # @rbs name: String|Symbol
      # @rbs include_private: bool
      # @rbs return: bool
      def respond_to_missing?(name, include_private = false)
        callable?(name) || super
      end

      private

      # No Wasm operand stack, boxed values, or recursive Ruby calls here.
      # Every register array contains only normalized i32 Integers. Void calls
      # use destination -1; execute returns an unused integer for a void entry.
      # @rbs index: Integer
      # @rbs arguments: Array[Integer]
      # @rbs return: Integer
      def execute(index, arguments)
        function = @ir.functions[index] || raise(Wardite::EvalError, "invalid function index #{index}")
        frame = Frame.new(function, -1) #: Wardite::Efflorescence::Frame
        arguments.each_with_index { |value, i| frame.registers[i] = value }
        frames = [] #: Array[Wardite::Efflorescence::Frame]
        frames << frame
        registers = frame.registers
        instructions = function.instructions
        pc = 0
        loop do
          instruction = instructions[pc] || raise(Wardite::EvalError, "Efflorescence: invalid MIR PC #{pc}")
          pc += 1
          case instruction[0]
          when Opcode::COPY
            registers[instruction[1]] = registers[instruction[2]]
          when Opcode::I32_ADD
            registers[instruction[1]] = (registers[instruction[2]] + registers[instruction[3]]) & 0xffffffff
          when Opcode::I32_SUB
            registers[instruction[1]] = (registers[instruction[2]] - registers[instruction[3]]) & 0xffffffff
          when Opcode::I32_MUL
            # A full unsigned i32 product can overflow Spinel's native signed
            # word. Split into 16-bit limbs; all intermediates fit in 49 bits.
            left = registers[instruction[2]]
            right = registers[instruction[3]]
            low = (left & 0xffff) * right
            high = (((left >> 16) * right) & 0xffff) << 16
            registers[instruction[1]] = (low + high) & 0xffffffff
          when Opcode::I32_XOR
            registers[instruction[1]] = registers[instruction[2]] ^ registers[instruction[3]]
          when Opcode::I32_SHL
            registers[instruction[1]] = (registers[instruction[2]] << (registers[instruction[3]] & 31)) & 0xffffffff
          when Opcode::I32_SHR_U
            registers[instruction[1]] = registers[instruction[2]] >> (registers[instruction[3]] & 31)
          when Opcode::I32_EQZ
            registers[instruction[1]] = registers[instruction[2]] == 0 ? 1 : 0
          when Opcode::BR
            pc = instruction[1]
          when Opcode::BR_IF
            pc = instruction[2] if registers[instruction[1]] != 0
          when Opcode::CALL
            frame.pc = pc
            callee = @ir.functions[instruction[2]] || raise(Wardite::EvalError, "invalid MIR call target")
            next_frame = Frame.new(callee, instruction[1])
            argument = 0
            while argument < callee.parameter_count
              next_frame.registers[argument] = registers[instruction[argument + 3]]
              argument += 1
            end
            frames << next_frame
            frame = next_frame
            registers = frame.registers
            instructions = frame.function.instructions
            pc = 0
          when Opcode::RETURN
            value = instruction[1] < 0 ? 0 : registers[instruction[1]]
            destination = frame.return_register
            frames.pop
            return value if frames.empty?
            frame = frames.last || raise(Wardite::EvalError, "missing MIR caller")
            registers = frame.registers
            registers[destination] = value if destination >= 0
            instructions = frame.function.instructions
            pc = frame.pc
          when Opcode::TRAP
            raise Wardite::Unreachable, "unreachable op"
          else
            raise Wardite::EvalError, "Efflorescence: invalid MIR opcode #{instruction[0]}"
          end
        end
      end
    end
  end
end
