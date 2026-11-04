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
      I32_ADD_IMM = 13
      I32_SUB_IMM = 14
      I32_MUL_IMM = 15
      I32_XOR_IMM = 16
      I32_SHL_IMM = 17
      I32_SHR_U_IMM = 18
      BR_IF_ZERO = 19
      I32_XOR_SHR_U_IMM = 20
      I32_XOR_SHL_IMM = 21
      PROFILE = 22

      NAMES = %w[COPY I32_ADD I32_SUB I32_MUL I32_XOR I32_SHL I32_SHR_U I32_EQZ
                 BR BR_IF CALL RETURN TRAP I32_ADD_IMM I32_SUB_IMM I32_MUL_IMM
                 I32_XOR_IMM I32_SHL_IMM I32_SHR_U_IMM BR_IF_ZERO
                 I32_XOR_SHR_U_IMM I32_XOR_SHL_IMM PROFILE].freeze

      # These are semantic register accesses, excluding frame initialization.
      # @rbs instruction: Wardite::Efflorescence::Instruction
      # @rbs return: Array[Integer]
      def self.read_positions(instruction)
        case instruction[0]
        when COPY, I32_EQZ, I32_ADD_IMM, I32_SUB_IMM, I32_MUL_IMM,
             I32_XOR_IMM, I32_SHL_IMM, I32_SHR_U_IMM, I32_XOR_SHR_U_IMM, I32_XOR_SHL_IMM
          [2]
        when I32_ADD, I32_SUB, I32_MUL, I32_XOR, I32_SHL, I32_SHR_U
          [2, 3]
        when BR_IF, BR_IF_ZERO
          [1]
        when CALL
          (3...instruction.size).to_a
        when RETURN
          instruction[1] < 0 ? [] : [1]
        when BR, TRAP, PROFILE
          []
        else
          raise UnsupportedFeature, "Efflorescence: unknown MIR opcode #{instruction[0]}"
        end
      end

      # @rbs instruction: Wardite::Efflorescence::Instruction
      # @rbs return: Integer
      def self.destination(instruction)
        opcode = instruction[0]
        if opcode <= I32_EQZ || opcode == CALL ||
            (opcode >= I32_ADD_IMM && opcode <= I32_SHR_U_IMM) ||
            opcode == I32_XOR_SHR_U_IMM || opcode == I32_XOR_SHL_IMM
          instruction[1]
        else
          -1
        end
      end

      # @rbs instruction: Wardite::Efflorescence::Instruction
      # @rbs return: Integer
      def self.target_position(instruction)
        case instruction[0]
        when BR then 1
        when BR_IF, BR_IF_ZERO then 2
        else -1
        end
      end
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

      # @rbs return: Wardite::Efflorescence::Instruction
      def copy
        Instruction.new(@operands.dup)
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
      attr_reader :constant_registers #: Array[Integer]
      attr_reader :bytecode #: Array[Integer]
      attr_reader :calls #: Array[Wardite::Efflorescence::CallSite]

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
        @constant_registers = []
        @bytecode = []
        @calls = []
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

      # @rbs value: Integer
      # @rbs return: Integer
      def allocate_constant(value)
        slot = allocate_register(value)
        @constant_registers << slot
        slot
      end

      # @rbs instructions: Array[Wardite::Efflorescence::Instruction]
      # @rbs return: void
      def replace_instructions(instructions)
        @instructions = instructions
      end

      # @rbs code: Array[Integer]
      # @rbs calls: Array[Wardite::Efflorescence::CallSite]
      # @rbs return: void
      def install_code(code, calls)
        @bytecode = code
        @calls = calls
      end

      # @rbs return: Wardite::Efflorescence::Function
      def copy
        result = Function.new(@index, @parameter_types, @result_types, @local_count)
        index = @parameter_types.size + @local_count
        while index < register_count
          if @constant_registers.include?(index)
            result.allocate_constant(initial_value(index))
          else
            result.allocate_register(initial_value(index))
          end
          index += 1
        end
        result.replace_instructions(@instructions.map { |instruction| instruction.copy })
        result
      end
    end

    class CallSite
      attr_reader :callee #: Wardite::Efflorescence::Function
      attr_reader :arguments #: Array[Integer]

      # @rbs callee: Wardite::Efflorescence::Function
      # @rbs arguments: Array[Integer]
      def initialize(callee, arguments)
        @callee = callee
        @arguments = arguments
      end
    end

    class IR
      attr_reader :functions #: Array[Wardite::Efflorescence::Function]

      # @rbs functions: Array[Wardite::Efflorescence::Function]
      def initialize(functions)
        @functions = functions
      end

      # @rbs return: Wardite::Efflorescence::IR
      def copy
        IR.new(@functions.map { |function| function.copy })
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
        # Constants are initialized once and never written by verified MIR.
        # Copying the template also avoids zero-filling and then overwriting
        # every slot in a second loop on a newly allocated frame.
        @registers = function.initial_registers.dup
        @local_start = function.parameter_count
        @local_end = @local_start + function.local_count
        @return_register = return_register
        @pc = 0
      end

      # @rbs return_register: Integer
      # @rbs return: void
      def reset(return_register)
        # CALL overwrites all parameters; Wasm initializes only non-parameter
        # locals to zero. RegisterValidation proves that every temporary is
        # written before it is read, including across joins and backedges.
        index = @local_start
        while index < @local_end
          @registers[index] = 0
          index += 1
        end
        @return_register = return_register
        @pc = 0
      end
    end

    # An invocation owns its pools. Active recursive frames never enter the
    # free list, and overlapping/reentrant public calls cannot share a frame.
    class FramePool
      attr_reader :created #: Integer

      # @rbs function: Wardite::Efflorescence::Function
      # @rbs reuse: bool
      def initialize(function, reuse)
        @function = function
        @reuse = reuse
        @free = [] #: Array[Wardite::Efflorescence::Frame]
        @created = 0
      end

      # @rbs destination: Integer
      # @rbs return: Wardite::Efflorescence::Frame
      def acquire(destination)
        if @reuse
          frame = @free.pop
          if frame
            frame.reset(destination)
            return frame
          end
        end
        @created += 1
        Frame.new(@function, destination)
      end

      # @rbs frame: Wardite::Efflorescence::Frame
      # @rbs return: void
      def release(frame)
        @free << frame if @reuse
      end
    end
  end
end
