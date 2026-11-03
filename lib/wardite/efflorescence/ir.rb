# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    class UnsupportedFeature < Wardite::LoadError; end
    class TranslationError < Wardite::LoadError; end

    module Opcode
      COPY = 0
      I32_ADD = 1
      I32_SUB = 2
      I32_MUL = 3
      I32_XOR = 4
      I32_SHL = 5
      I32_SHR_U = 6
      I32_EQZ = 7
      BR = 8
      BR_IF = 9
      CALL = 10
      RETURN = 11
      TRAP = 12
    end

    # A small wrapper keeps operand reads monomorphic even when a compiler
    # represents the outer instruction table as a generic object array.
    class Instruction
      attr_reader :operands #: Array[Integer]

      # @rbs operands: Array[Integer]
      def initialize(operands)
        @operands = operands
      end

      # @rbs index: Integer
      # @rbs return: Integer
      def [](index)
        @operands.fetch(index)
      end

      # @rbs index: Integer
      # @rbs value: Integer
      # @rbs return: Integer
      def []=(index, value)
        @operands[index] = value
      end

      # @rbs return: Integer
      def size
        @operands.size
      end
    end

    # Each instruction holds an integer array. Sources and destinations are slots
    # in initial_registers; constants occupy immutable, preinitialized slots.
    # This is deliberately separate from translation and execution so later
    # function-level optimization passes can consume and produce MIR.
    class Function
      attr_reader :index #: Integer
      attr_reader :parameter_types #: Array[Symbol]
      attr_reader :result_types #: Array[Symbol]
      attr_reader :local_count #: Integer
      attr_reader :instructions #: Array[Wardite::Efflorescence::Instruction]
      attr_reader :initial_registers #: Array[Integer]

      # @rbs index: Integer
      # @rbs parameter_types: Array[Symbol]
      # @rbs result_types: Array[Symbol]
      # @rbs local_count: Integer
      def initialize(index, parameter_types, result_types, local_count)
        @index = index
        @parameter_types = parameter_types.dup
        @result_types = result_types.dup
        @local_count = local_count
        @instructions = []
        @initial_registers = Array.new(parameter_types.size + local_count, 0)
      end

      # @rbs return: Integer
      def register_count
        @initial_registers.size
      end

      # @rbs return: Integer
      def parameter_count
        @parameter_types.size
      end

      # @rbs index: Integer
      # @rbs return: Integer
      def initial_value(index)
        @initial_registers.fetch(index)
      end

      # @rbs value: Integer
      # @rbs return: Integer
      def allocate_register(value)
        slot = @initial_registers.size
        @initial_registers << value
        slot
      end
    end

    class IR
      attr_reader :functions #: Array[Wardite::Efflorescence::Function]

      # @rbs functions: Array[Wardite::Efflorescence::Function]
      def initialize(functions)
        @functions = functions
      end
    end

    class Frame
      attr_reader :function #: Wardite::Efflorescence::Function
      attr_reader :registers #: Array[Integer]
      attr_reader :return_register #: Integer
      attr_accessor :pc #: Integer

      # @rbs function: Wardite::Efflorescence::Function
      # @rbs return_register: Integer
      def initialize(function, return_register)
        @function = function
        @registers = Array.new(function.register_count, 0)
        index = 0
        while index < function.register_count
          @registers[index] = function.initial_value(index)
          index += 1
        end
        @return_register = return_register
        @pc = 0
      end
    end
  end
end
