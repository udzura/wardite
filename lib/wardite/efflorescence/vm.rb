# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    class VM
      attr_reader :instance #: Wardite::Instance
      attr_reader :ir #: Wardite::Efflorescence::IR
      attr_reader :semantic_ir #: Wardite::Efflorescence::IR
      attr_reader :optimized_ir #: Wardite::Efflorescence::IR
      attr_reader :metrics #: Wardite::Efflorescence::Metrics

      # @rbs instance: Wardite::Instance
      # @rbs disabled_optimizations: Array[Symbol]
      # @rbs profile: bool
      def initialize(instance, disabled_optimizations: [], profile: false)
        @instance = instance
        configuration = Configuration.new(disabled_optimizations)
        @flat = configuration.enabled?(:flat)
        @reuse_frames = configuration.enabled?(:frames)
        @profiling = profile
        @metrics = Metrics.new
        @semantic_ir = Translator.new(instance).translate
        @optimized_ir = Optimizer.new(configuration).optimize(@semantic_ir)
        @optimized_ir.functions.each { |function| RegisterValidation.new.validate(function) }
        @ir = profile ? Instrumentation.new.instrument(@optimized_ir) : @optimized_ir
        Lowerer.new.compile(@ir) if @flat
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

      # @rbs return: String
      def dump_mir
        inspection = Inspection.new
        "Semantic MIR (#{inspection.statistics(@semantic_ir)})\n#{inspection.disassemble(@semantic_ir)}\n" \
          "Optimized MIR (#{inspection.statistics(@optimized_ir)})\n#{inspection.disassemble(@optimized_ir)}"
      end

      private

      # A concrete return type breaks the inference cycle between the current
      # frame and the array it is restored from after every internal RETURN.
      # @rbs return: Wardite::Efflorescence::Frame
      def current_frame(frames)
        frames.last || raise(Wardite::EvalError, "missing MIR caller")
      end

      # No Wasm operand stack, boxed values, or recursive Ruby calls here.
      # Every register array contains only normalized i32 Integers. Void calls
      # use destination -1; execute returns an unused integer for a void entry.
      # @rbs index: Integer
      # @rbs arguments: Array[Integer]
      # @rbs return: Integer
      def execute(index, arguments)
        pools = [] #: Array[Wardite::Efflorescence::FramePool]
        @ir.functions.each { |function| pools << FramePool.new(function, @reuse_frames) }
        function = @ir.functions[index] || raise(Wardite::EvalError, "invalid function index #{index}")
        pool = pools[function.index]
        raise Wardite::EvalError, "missing MIR frame pool" unless pool
        frame = pool.acquire(-1)
        arguments.each_with_index { |value, i| frame.registers[i] = value }
        @metrics = Metrics.new if @profiling
        @flat ? execute_flat(frame, pools) : execute_semantic(frame, pools)
      ensure
        if @profiling
          created = 0
          pools.each { |pool| created += pool.created }
          @metrics.frames_created = created
        end
      end

      # @rbs frame: Wardite::Efflorescence::Frame
      # @rbs pools: Array[Wardite::Efflorescence::FramePool]
      # @rbs return: Integer
      def execute_semantic(frame, pools)
        frames = [] #: Array[Wardite::Efflorescence::Frame]
        frames << frame
        registers = frame.registers
        instructions = frame.function.instructions
        pc = 0
        loop do
          instruction = instructions[pc] || raise(Wardite::EvalError, "Efflorescence: invalid MIR PC #{pc}")
          pc += 1
          # Integer literal labels let Spinel emit a C switch. Keep the
          # Opcode comments in sync; the dispatch contract test checks them.
          case instruction[0]
          when 0 # Opcode::COPY
            registers[instruction[1]] = registers[instruction[2]]
          when 1 # Opcode::I32_ADD
            registers[instruction[1]] = (registers[instruction[2]] + registers[instruction[3]]) & 0xffffffff
          when 2 # Opcode::I32_SUB
            registers[instruction[1]] = (registers[instruction[2]] - registers[instruction[3]]) & 0xffffffff
          when 3 # Opcode::I32_MUL
            # A full unsigned i32 product can overflow Spinel's native signed
            # word. Split into 16-bit limbs; all intermediates fit in 49 bits.
            left = registers[instruction[2]]
            right = registers[instruction[3]]
            low = (left & 0xffff) * right
            high = (((left >> 16) * right) & 0xffff) << 16
            registers[instruction[1]] = (low + high) & 0xffffffff
          when 4 # Opcode::I32_XOR
            registers[instruction[1]] = registers[instruction[2]] ^ registers[instruction[3]]
          when 5 # Opcode::I32_SHL
            registers[instruction[1]] = (registers[instruction[2]] << (registers[instruction[3]] & 31)) & 0xffffffff
          when 6 # Opcode::I32_SHR_U
            registers[instruction[1]] = registers[instruction[2]] >> (registers[instruction[3]] & 31)
          when 7 # Opcode::I32_EQZ
            registers[instruction[1]] = registers[instruction[2]] == 0 ? 1 : 0
          when 13 # Opcode::I32_ADD_IMM
            registers[instruction[1]] = (registers[instruction[2]] + instruction[3]) & 0xffffffff
          when 14 # Opcode::I32_SUB_IMM
            registers[instruction[1]] = (registers[instruction[2]] - instruction[3]) & 0xffffffff
          when 15 # Opcode::I32_MUL_IMM
            left = registers[instruction[2]]
            right = instruction[3]
            low = (left & 0xffff) * right
            high = (((left >> 16) * right) & 0xffff) << 16
            registers[instruction[1]] = (low + high) & 0xffffffff
          when 16 # Opcode::I32_XOR_IMM
            registers[instruction[1]] = registers[instruction[2]] ^ instruction[3]
          when 17 # Opcode::I32_SHL_IMM
            registers[instruction[1]] = (registers[instruction[2]] << (instruction[3] & 31)) & 0xffffffff
          when 18 # Opcode::I32_SHR_U_IMM
            registers[instruction[1]] = registers[instruction[2]] >> (instruction[3] & 31)
          when 20 # Opcode::I32_XOR_SHR_U_IMM
            value = registers[instruction[2]]
            registers[instruction[1]] = value ^ (value >> instruction[3])
          when 21 # Opcode::I32_XOR_SHL_IMM
            value = registers[instruction[2]]
            registers[instruction[1]] = (value ^ (value << instruction[3])) & 0xffffffff
          when 8 # Opcode::BR
            pc = instruction[1]
          when 9 # Opcode::BR_IF
            pc = instruction[2] if registers[instruction[1]] != 0
          when 19 # Opcode::BR_IF_ZERO
            pc = instruction[2] if registers[instruction[1]] == 0
          when 10 # Opcode::CALL
            frame.pc = pc
            callee = @ir.functions[instruction[2]] || raise(Wardite::EvalError, "invalid MIR call target")
            pool = pools[callee.index]
            raise Wardite::EvalError, "missing MIR frame pool" unless pool
            next_frame = pool.acquire(instruction[1])
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
          when 11 # Opcode::RETURN
            value = instruction[1] < 0 ? 0 : registers[instruction[1]]
            destination = frame.return_register
            frames.pop
            pool = pools[frame.pool_index]
            raise Wardite::EvalError, "missing MIR frame pool" unless pool
            pool.release(frame)
            return value if frames.empty?
            frame = current_frame(frames)
            registers = frame.registers
            registers[destination] = value if destination >= 0
            instructions = frame.function.instructions
            pc = frame.pc
          when 12 # Opcode::TRAP
            raise Wardite::Unreachable, "unreachable op"
          when 22 # Opcode::PROFILE
            @metrics.record(instruction[1], instruction[2], instruction[3])
          else
            raise Wardite::EvalError, "Efflorescence: invalid MIR opcode #{instruction[0]}"
          end
        end
      end
      # @rbs frame: Wardite::Efflorescence::Frame
      # @rbs pools: Array[Wardite::Efflorescence::FramePool]
      # @rbs return: Integer
      def execute_flat(frame, pools)
        frames = [] #: Array[Wardite::Efflorescence::Frame]
        frames << frame
        registers = frame.registers
        instructions = frame.function.bytecode
        pc = 0
        loop do
          opcode = instructions.fetch(pc)
          a = instructions.fetch(pc + 1)
          # PCs still advance by four words, but short instructions do not
          # read their unused b/c padding. Control transfers skip the increment.
          # Integer literal labels let Spinel emit a C switch. Keep the
          # Opcode comments in sync; the dispatch contract test checks them.
          case opcode
          when 0 # Opcode::COPY
            b = instructions.fetch(pc + 2)
            registers[a] = registers[b]
          when 1 # Opcode::I32_ADD
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = (registers[b] + registers[c]) & 0xffffffff
          when 2 # Opcode::I32_SUB
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = (registers[b] - registers[c]) & 0xffffffff
          when 3 # Opcode::I32_MUL
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            # A full unsigned i32 product can overflow Spinel's native signed
            # word. Split into 16-bit limbs; all intermediates fit in 49 bits.
            left = registers[b]
            right = registers[c]
            low = (left & 0xffff) * right
            high = (((left >> 16) * right) & 0xffff) << 16
            registers[a] = (low + high) & 0xffffffff
          when 4 # Opcode::I32_XOR
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = registers[b] ^ registers[c]
          when 5 # Opcode::I32_SHL
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = (registers[b] << (registers[c] & 31)) & 0xffffffff
          when 6 # Opcode::I32_SHR_U
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = registers[b] >> (registers[c] & 31)
          when 7 # Opcode::I32_EQZ
            b = instructions.fetch(pc + 2)
            registers[a] = registers[b] == 0 ? 1 : 0
          when 13 # Opcode::I32_ADD_IMM
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = (registers[b] + c) & 0xffffffff
          when 14 # Opcode::I32_SUB_IMM
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = (registers[b] - c) & 0xffffffff
          when 15 # Opcode::I32_MUL_IMM
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            left = registers[b]
            right = c
            low = (left & 0xffff) * right
            high = (((left >> 16) * right) & 0xffff) << 16
            registers[a] = (low + high) & 0xffffffff
          when 16 # Opcode::I32_XOR_IMM
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = registers[b] ^ c
          when 17 # Opcode::I32_SHL_IMM
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = (registers[b] << (c & 31)) & 0xffffffff
          when 18 # Opcode::I32_SHR_U_IMM
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = registers[b] >> (c & 31)
          when 20 # Opcode::I32_XOR_SHR_U_IMM
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            value = registers[b]
            registers[a] = value ^ (value >> c)
          when 21 # Opcode::I32_XOR_SHL_IMM
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            value = registers[b]
            registers[a] = (value ^ (value << c)) & 0xffffffff
          when 8 # Opcode::BR
            pc = a
            next
          when 9 # Opcode::BR_IF
            b = instructions.fetch(pc + 2)
            if registers[a] != 0
              pc = b
              next
            end
          when 19 # Opcode::BR_IF_ZERO
            b = instructions.fetch(pc + 2)
            if registers[a] == 0
              pc = b
              next
            end
          when 10 # Opcode::CALL
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            frame.pc = pc + Lowerer::WIDTH
            site = frame.function.call_site(b)
            pool = pools[site.pool_index]
            raise Wardite::EvalError, "missing MIR frame pool" unless pool
            next_frame = pool.acquire(a)
            if c >= 0
              next_frame.registers[0] = registers[c]
            else
              site.copy_arguments(next_frame.registers, registers)
            end
            frames << next_frame
            frame = next_frame
            registers = frame.registers
            instructions = frame.function.bytecode
            pc = 0
            next
          when 11 # Opcode::RETURN
            value = a < 0 ? 0 : registers[a]
            destination = frame.return_register
            frames.pop
            pool = pools[frame.pool_index]
            raise Wardite::EvalError, "missing MIR frame pool" unless pool
            pool.release(frame)
            return value if frames.empty?
            frame = current_frame(frames)
            registers = frame.registers
            registers[destination] = value if destination >= 0
            instructions = frame.function.bytecode
            pc = frame.pc
            next
          when 12 # Opcode::TRAP
            raise Wardite::Unreachable, "unreachable op"
          when 22 # Opcode::PROFILE
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            @metrics.record(a, b, c)
          else
            raise Wardite::EvalError, "Efflorescence: invalid MIR opcode #{opcode}"
          end
          pc += Lowerer::WIDTH
        end
      end
    end
  end
end
