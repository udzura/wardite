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

      I32_EQ = 23
      I32_NE = 24
      I32_LTS = 25
      I32_LTU = 26
      I32_GTS = 27
      I32_GTU = 28
      I32_LES = 29
      I32_LEU = 30
      I32_GES = 31
      I32_GEU = 32
      I32_CLZ = 33
      I32_CTZ = 34
      I32_POPCNT = 35
      I32_DIV_S = 36
      I32_DIV_U = 37
      I32_REM_S = 38
      I32_REM_U = 39
      I32_AND = 40
      I32_OR = 41
      I32_SHR_S = 42
      I32_ROTL = 43
      I32_ROTR = 44
      I32_EXTEND8_S = 45
      I32_EXTEND16_S = 46
      COPY_REF = 47
      EH_ENTER = 48
      EH_TRIM = 49
      THROW = 50
      THROW_REF = 51

      GLOBAL_GET = 52
      GLOBAL_SET = 53
      I32_LOAD = 54
      I32_LOAD8_S = 55
      I32_LOAD8_U = 56
      I32_LOAD16_S = 57
      I32_LOAD16_U = 58
      I32_STORE = 59
      I32_STORE8 = 60
      I32_STORE16 = 61
      MEMORY_SIZE = 62
      MEMORY_GROW = 63
      MEMORY_INIT = 64
      MEMORY_COPY = 65
      MEMORY_FILL = 66

      NAMES = %w[COPY I32_ADD I32_SUB I32_MUL I32_XOR I32_SHL I32_SHR_U I32_EQZ
                 BR BR_IF CALL RETURN TRAP I32_ADD_IMM I32_SUB_IMM I32_MUL_IMM
                 I32_XOR_IMM I32_SHL_IMM I32_SHR_U_IMM BR_IF_ZERO
                 I32_XOR_SHR_U_IMM I32_XOR_SHL_IMM PROFILE
                 I32_EQ I32_NE I32_LTS I32_LTU I32_GTS I32_GTU I32_LES I32_LEU I32_GES I32_GEU I32_CLZ I32_CTZ I32_POPCNT I32_DIV_S I32_DIV_U I32_REM_S I32_REM_U I32_AND I32_OR I32_SHR_S I32_ROTL I32_ROTR I32_EXTEND8_S I32_EXTEND16_S COPY_REF EH_ENTER EH_TRIM THROW THROW_REF
                 GLOBAL_GET GLOBAL_SET I32_LOAD I32_LOAD8_S I32_LOAD8_U I32_LOAD16_S I32_LOAD16_U I32_STORE I32_STORE8 I32_STORE16 MEMORY_SIZE MEMORY_GROW MEMORY_INIT MEMORY_COPY MEMORY_FILL].freeze

      # These are semantic register accesses, excluding frame initialization.
      # @rbs instruction: Wardite::Efflorescence::Instruction
      # @rbs return: Array[Integer]
      def self.read_positions(instruction)
        case instruction[0]
        when GLOBAL_SET, I32_LOAD, I32_LOAD8_S, I32_LOAD8_U, I32_LOAD16_S, I32_LOAD16_U, MEMORY_GROW,
             COPY, COPY_REF, I32_EQZ, I32_CLZ, I32_CTZ, I32_POPCNT, I32_EXTEND8_S, I32_EXTEND16_S, I32_ADD_IMM, I32_SUB_IMM, I32_MUL_IMM,
             I32_XOR_IMM, I32_SHL_IMM, I32_SHR_U_IMM, I32_XOR_SHR_U_IMM, I32_XOR_SHL_IMM
          [2]
        when I32_ADD, I32_SUB, I32_MUL, I32_XOR, I32_SHL, I32_SHR_U,
             I32_EQ, I32_NE, I32_LTS, I32_LTU, I32_GTS, I32_GTU, I32_LES, I32_LEU, I32_GES, I32_GEU,
             I32_DIV_S, I32_DIV_U, I32_REM_S, I32_REM_U, I32_AND, I32_OR, I32_SHR_S, I32_ROTL, I32_ROTR
          [2, 3]
        when BR_IF, BR_IF_ZERO
          [1]
        when CALL
          (3...instruction.size).to_a
        when RETURN
          instruction[1] < 0 ? [] : [1]
        when I32_STORE, I32_STORE8, I32_STORE16
          [1, 2]
        when THROW_REF
          [1]
        when BR, TRAP, PROFILE, EH_ENTER, EH_TRIM, THROW, GLOBAL_GET, MEMORY_SIZE, MEMORY_INIT, MEMORY_COPY, MEMORY_FILL
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
            opcode == I32_XOR_SHR_U_IMM || opcode == I32_XOR_SHL_IMM ||
            (opcode >= I32_EQ && opcode <= COPY_REF) || opcode == GLOBAL_GET ||
            (opcode >= I32_LOAD && opcode <= I32_LOAD16_U) || opcode == MEMORY_SIZE || opcode == MEMORY_GROW
          instruction[1]
        else
          -1
        end
      end

      # @rbs opcode: Integer
      # @rbs return: bool
      def self.may_throw?(opcode)
        opcode == CALL || opcode == THROW || opcode == THROW_REF
      end

      # @rbs opcode: Integer
      # @rbs return: bool
      def self.may_trap?(opcode)
        opcode == TRAP || opcode == THROW_REF || (opcode >= I32_DIV_S && opcode <= I32_REM_U) ||
          (opcode >= I32_LOAD && opcode <= I32_STORE16) || memory_site?(opcode)
      end

      # @rbs opcode: Integer
      # @rbs return: bool
      def self.side_effect?(opcode)
        may_throw?(opcode) || may_trap?(opcode) || reads_store?(opcode) || writes_store?(opcode) ||
          [BR, BR_IF, BR_IF_ZERO, RETURN, EH_ENTER, EH_TRIM, PROFILE].include?(opcode)
      end

      # @rbs opcode: Integer
      # @rbs return: bool
      def self.memory_site?(opcode)
        opcode == MEMORY_INIT || opcode == MEMORY_COPY || opcode == MEMORY_FILL
      end

      # @rbs opcode: Integer
      # @rbs return: bool
      def self.reads_store?(opcode)
        opcode == GLOBAL_GET || (opcode >= I32_LOAD && opcode <= I32_LOAD16_U) ||
          opcode == MEMORY_SIZE || opcode == MEMORY_GROW || opcode == MEMORY_INIT || opcode == MEMORY_COPY
      end

      # @rbs opcode: Integer
      # @rbs return: bool
      def self.writes_store?(opcode)
        opcode == GLOBAL_SET || (opcode >= I32_STORE && opcode <= I32_STORE16) ||
          opcode == MEMORY_GROW || memory_site?(opcode)
      end

      # @rbs opcode: Integer
      # @rbs return: bool
      def self.terminal?(opcode)
        [BR, RETURN, TRAP, THROW, THROW_REF].include?(opcode)
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

    class Tag
      attr_reader :parameter_types #: Array[Symbol]

      # @rbs parameter_types: Array[Symbol]
      def initialize(parameter_types)
        @parameter_types = parameter_types.dup.freeze
      end
    end

    class ExceptionValue
      attr_reader :tag #: Wardite::Efflorescence::Tag
      attr_reader :payload #: Array[Integer]

      # @rbs tag: Wardite::Efflorescence::Tag
      # @rbs payload: Array[Integer]
      def initialize(tag, payload)
        @tag = tag
        @payload = payload.dup.freeze
        freeze
      end
    end

    class CatchTarget
      attr_reader :tag_index #: Integer
      attr_reader :payload_registers #: Array[Integer]
      attr_reader :reference_register #: Integer
      attr_accessor :target_pc #: Integer
      attr_reader :handler_depth #: Integer

      # @rbs tag_index: Integer
      # @rbs payload_registers: Array[Integer]
      # @rbs reference_register: Integer
      # @rbs pc: Integer
      # @rbs handler_depth: Integer
      def initialize(tag_index, payload_registers, reference_register, pc, handler_depth)
        @tag_index = tag_index
        @payload_registers = payload_registers.dup
        @reference_register = reference_register
        @target_pc = pc
        @handler_depth = handler_depth
      end

      # @rbs register: Integer
      # @rbs return: void
      def replace_reference_register(register)
        @reference_register = register
      end

      # @rbs return: Wardite::Efflorescence::CatchTarget
      def copy
        CatchTarget.new(@tag_index, @payload_registers, @reference_register, @target_pc, @handler_depth)
      end

      # @rbs return: Array[Integer]
      def destinations
        @reference_register < 0 ? @payload_registers.dup : @payload_registers + [@reference_register]
      end
    end

    class HandlerDescriptor
      attr_reader :clauses #: Array[Wardite::Efflorescence::CatchTarget]

      # @rbs clauses: Array[Wardite::Efflorescence::CatchTarget]
      def initialize(clauses)
        @clauses = clauses
      end

      # @rbs return: Wardite::Efflorescence::HandlerDescriptor
      def copy
        HandlerDescriptor.new(@clauses.map { |clause| clause.copy })
      end
    end

    class ThrowSite
      attr_reader :tag_index #: Integer
      attr_reader :payload_registers #: Array[Integer]

      # @rbs tag_index: Integer
      # @rbs payload_registers: Array[Integer]
      def initialize(tag_index, payload_registers)
        @tag_index = tag_index
        @payload_registers = payload_registers.dup
      end

      # @rbs return: Wardite::Efflorescence::ThrowSite
      def copy
        ThrowSite.new(@tag_index, @payload_registers)
      end
    end

    # Bulk operands stay static in the Function. Values remain in Frame registers.
    class MemorySite
      attr_reader :sources #: Array[Integer]
      attr_reader :memory_index #: Integer
      attr_reader :source_memory_index #: Integer
      attr_reader :data_index #: Integer

      # @rbs sources: Array[Integer]
      # @rbs memory_index: Integer
      # @rbs source_memory_index: Integer
      # @rbs data_index: Integer
      def initialize(sources, memory_index: 0, source_memory_index: 0, data_index: -1)
        @sources = sources.dup
        @memory_index = memory_index
        @source_memory_index = source_memory_index
        @data_index = data_index
      end

      # @rbs return: Wardite::Efflorescence::MemorySite
      def copy
        MemorySite.new(@sources, memory_index: @memory_index, source_memory_index: @source_memory_index, data_index: @data_index)
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
        # Keep generic CFG callbacks from widening native operand/PC reads.
        Integer(@operands.fetch(index))
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
      attr_reader :register_types #: Array[Symbol]
      attr_reader :handlers #: Array[Wardite::Efflorescence::HandlerDescriptor]
      attr_reader :flat_handlers #: Array[Wardite::Efflorescence::HandlerDescriptor]
      attr_reader :throw_sites #: Array[Wardite::Efflorescence::ThrowSite]
      attr_accessor :uses_eh #: bool
      attr_accessor :uses_store #: bool
      attr_reader :memory_sites #: Array[Wardite::Efflorescence::MemorySite]
      attr_reader :calls #: Array[Wardite::Efflorescence::CallSite]

      # @rbs index: Integer
      # @rbs parameter_types: Array[Symbol]
      # @rbs result_types: Array[Symbol]
      # @rbs local_count: Integer
      # @rbs local_types: Array[Symbol]?
      def initialize(index, parameter_types, result_types, local_count, local_types: nil)
        @index = index
        @parameter_types = parameter_types.dup
        @result_types = result_types.dup
        @local_count = local_count
        @register_types = parameter_types + (local_types || Array.new(local_count, :i32))
        @handlers = []
        @flat_handlers = []
        @throw_sites = []
        @memory_sites = []
        @uses_store = false
        @uses_eh = @register_types.include?(:exnref)
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
      # @rbs type: Symbol
      def allocate_register(value, type: :i32)
        slot = @initial_registers.size
        @initial_registers << value
        @register_types << type
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

      # Keep the element type at the array boundary. In particular, fetch on
      # an object array makes Spinel fall back to a generic boxed container.
      # @rbs index: Integer
      # @rbs return: Wardite::Efflorescence::CallSite
      def call_site(index)
        @calls[index] || raise(Wardite::EvalError, "invalid MIR call site")
      end

      # @rbs index: Integer
      # @rbs return: Wardite::Efflorescence::MemorySite
      def memory_site(index)
        @memory_sites[index] || raise(Wardite::EvalError, "invalid MIR memory site")
      end

      # All PC consumers (rewrites, profiling, lowering) share this enumeration.
      # @rbs mapping: Array[Integer]
      # @rbs return: void
      def remap_targets!(mapping)
        @instructions.each do |instruction|
          position = Opcode.target_position(instruction)
          instruction[position] = mapping.fetch(instruction[position]) if position >= 0
        end
        remap_handler_targets!(@handlers, mapping)
      end

      # @rbs handlers: Array[Wardite::Efflorescence::HandlerDescriptor]
      # @rbs mapping: Array[Integer]
      # @rbs return: void
      def remap_handler_targets!(handlers, mapping)
        handlers.each do |handler|
          handler.clauses.each { |clause| clause.target_pc = mapping.fetch(clause.target_pc) }
        end
      end

      # @rbs return: void
      def lower_handlers
        @flat_handlers = @handlers.map { |handler| handler.copy }
        return if @flat_handlers.empty?
        mapping = (0..@instructions.size).map { |pc| pc * Lowerer::WIDTH }
        remap_handler_targets!(@flat_handlers, mapping)
      end

      # Rename MIR references, including operands stored outside instructions.
      # The caller supplies existing same-typed slots and validates the result.
      # @rbs mapping: Array[Integer]
      # @rbs return: void
      def replace_register_references!(mapping)
        @instructions.each do |instruction|
          Opcode.read_positions(instruction).each do |position|
            instruction[position] = mapping.fetch(instruction[position])
          end
          destination = Opcode.destination(instruction)
          instruction[1] = mapping.fetch(destination) if destination >= 0
        end
        @throw_sites.each { |site| site.payload_registers.map! { |register| mapping.fetch(register) } }
        @memory_sites.each { |site| site.sources.map! { |register| mapping.fetch(register) } }
        @handlers.each do |handler|
          handler.clauses.each do |clause|
            clause.payload_registers.map! { |register| mapping.fetch(register) }
            if clause.reference_register >= 0
              clause.replace_reference_register(mapping.fetch(clause.reference_register))
            end
          end
        end
      end

      # @rbs instruction: Wardite::Efflorescence::Instruction
      # @rbs return: Array[Integer]
      def reads(instruction)
        result = Opcode.read_positions(instruction).map { |position| instruction[position] }
        result += @throw_sites.fetch(instruction[1]).payload_registers if instruction[0] == Opcode::THROW
        result += memory_site(instruction[1]).sources if Opcode.memory_site?(instruction[0])
        result
      end

      # @rbs return: Wardite::Efflorescence::Function
      def copy
        result = Function.new(@index, @parameter_types, @result_types, @local_count, local_types: @register_types[@parameter_types.size, @local_count])
        result.uses_eh = @uses_eh
        result.uses_store = @uses_store
        @memory_sites.each { |site| result.memory_sites << site.copy }
        @handlers.each { |handler| result.handlers << handler.copy }
        @throw_sites.each { |site| result.throw_sites << site.copy }
        index = @parameter_types.size + @local_count
        while index < register_count
          if @constant_registers.include?(index)
            result.allocate_constant(initial_value(index))
          else
            result.allocate_register(initial_value(index), type: @register_types.fetch(index))
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
      attr_reader :pool_index #: Integer

      # @rbs callee: Wardite::Efflorescence::Function
      # @rbs arguments: Array[Integer]
      def initialize(callee, arguments)
        @callee = callee
        @arguments = arguments
        @pool_index = callee.index
      end

      # Keep the generic argument loop out of the interpreter's live locals.
      # The common single-argument path copies directly from the CALL operand.
      # @rbs target: Array[Integer]
      # @rbs source: Array[Integer]
      # @rbs return: void
      def copy_arguments(target, source)
        argument = 0
        count = @arguments.size
        while argument < count
          target[argument] = source[@arguments.fetch(argument)]
          argument += 1
        end
      end
    end

    class IR
      attr_reader :functions #: Array[Wardite::Efflorescence::Function]

      # @rbs functions: Array[Wardite::Efflorescence::Function]
      def initialize(functions)
        @functions = functions
      end

      # @rbs index: Integer
      # @rbs return: Wardite::Efflorescence::Function
      def function_at(index)
        @functions[index] || raise(Wardite::EvalError, "invalid MIR function index #{index}")
      end

      # @rbs return: Wardite::Efflorescence::IR
      def copy
        IR.new(@functions.map { |function| function.copy })
      end
    end

    class Frame
      attr_reader :function #: Wardite::Efflorescence::Function
      attr_reader :pool_index #: Integer
      attr_reader :registers #: Array[Integer]
      attr_reader :exception_registers #: Array[Wardite::Efflorescence::ExceptionValue?]
      attr_reader :handlers #: Array[Integer]
      attr_reader :return_register #: Integer
      attr_accessor :pc #: Integer

      # @rbs function: Wardite::Efflorescence::Function
      # @rbs return_register: Integer
      def initialize(function, return_register)
        @function = function
        @pool_index = function.index
        # Constants are initialized once and never written by verified MIR.
        # Copying the template also avoids zero-filling and then overwriting
        # every slot in a second loop on a newly allocated frame.
        @uses_eh = function.uses_eh
        @registers = function.initial_registers.dup
        @exception_registers = function.register_types.include?(:exnref) ? Array.new(function.register_count, nil) : []
        @handlers = []
        @local_start = function.parameter_count
        @local_end = @local_start + function.local_count
        @return_register = return_register
        @pc = 0
      end

      # @rbs return: void
      def clear_references
        @exception_registers.fill(nil)
        @handlers.clear
      end

      # @rbs depth: Integer
      # @rbs return: void
      def trim_handlers(depth)
        @handlers.pop while @handlers.size > depth
      end

      # @rbs return_register: Integer
      # @rbs return: void
      def reset(return_register)
        clear_references if @uses_eh
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
        @clear_references = function.uses_eh
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
        frame.clear_references if @clear_references
        @free << frame if @reuse
      end
    end
  end
end
