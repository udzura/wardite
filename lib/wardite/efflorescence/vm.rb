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
        @store_access = StoreAccess.new(instance.store)
        configuration = Configuration.new(disabled_optimizations)
        @reuse_frames = configuration.enabled?(:frames)
        @profiling = profile
        @metrics = Metrics.new
        @semantic_ir = Translator.new(instance).translate
        @optimized_ir = Optimizer.new(configuration).optimize(@semantic_ir)
        @optimized_ir.functions.each { |function| RegisterValidation.new.validate(function) }
        @ir = profile ? Instrumentation.new.instrument(@optimized_ir) : @optimized_ir
        Lowerer.new.compile(@ir)
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

      # @rbs value: Integer
      # @rbs return: Integer
      def signed(value)
        value >= 0x80000000 ? value - 0x100000000 : value
      end

      # Cold/new ALU paths stay outside the established hot-loop operations.
      # @rbs opcode: Integer
      # @rbs left: Integer
      # @rbs right: Integer
      # @rbs return: Integer
      def calculate(opcode, left, right)
        case opcode
        when Opcode::I32_EQ then left == right ? 1 : 0
        when Opcode::I32_NE then left != right ? 1 : 0
        when Opcode::I32_LTS then signed(left) < signed(right) ? 1 : 0
        when Opcode::I32_LTU then left < right ? 1 : 0
        when Opcode::I32_GTS then signed(left) > signed(right) ? 1 : 0
        when Opcode::I32_GTU then left > right ? 1 : 0
        when Opcode::I32_LES then signed(left) <= signed(right) ? 1 : 0
        when Opcode::I32_LEU then left <= right ? 1 : 0
        when Opcode::I32_GES then signed(left) >= signed(right) ? 1 : 0
        when Opcode::I32_GEU then left >= right ? 1 : 0
        when Opcode::I32_CLZ
          count = 32
          while left != 0
            left >>= 1
            count -= 1
          end
          count
        when Opcode::I32_CTZ
          return 32 if left == 0
          count = 0
          while (left & 1) == 0
            left >>= 1
            count += 1
          end
          count
        when Opcode::I32_POPCNT
          count = 0
          while left != 0
            left &= left - 1
            count += 1
          end
          count
        when Opcode::I32_DIV_S, Opcode::I32_REM_S
          raise Wardite::EvalError, "integer divide by zero" if right == 0
          a, b = signed(left), signed(right)
          if opcode == Opcode::I32_DIV_S && a == -2147483648 && b == -1
            raise Wardite::IntegerOverflow, "integer division overflow"
          end
          quotient = a.abs / b.abs
          quotient = -quotient if (a < 0) != (b < 0)
          (opcode == Opcode::I32_DIV_S ? quotient : a - quotient * b) & 0xffffffff
        when Opcode::I32_DIV_U, Opcode::I32_REM_U
          raise Wardite::EvalError, "integer divide by zero" if right == 0
          opcode == Opcode::I32_DIV_U ? left / right : left % right
        when Opcode::I32_AND then left & right
        when Opcode::I32_OR then left | right
        when Opcode::I32_SHR_S then (signed(left) >> (right & 31)) & 0xffffffff
        when Opcode::I32_ROTL, Opcode::I32_ROTR
          shift = right & 31
          shift = (32 - shift) & 31 if opcode == Opcode::I32_ROTR
          ((left << shift) | (left >> ((32 - shift) & 31))) & 0xffffffff
        when Opcode::I32_EXTEND8_S
          value = left & 255
          (value >= 128 ? value - 256 : value) & 0xffffffff
        when Opcode::I32_EXTEND16_S
          value = left & 65535
          (value >= 32768 ? value - 65536 : value) & 0xffffffff
        else
          raise Wardite::EvalError, "invalid i32 opcode"
        end
      end

      # The pending value owns its payload before any frame is released. No
      # Ruby raise/rescue is used to unwind the explicit Wasm call stack.
      # @rbs value: Wardite::Efflorescence::ExceptionValue
      # @rbs frames: Array[Wardite::Efflorescence::Frame]
      # @rbs pools: Array[Wardite::Efflorescence::FramePool]
      # @rbs return: Wardite::Efflorescence::Frame
      def propagate(value, frames, pools)
        until frames.empty?
          frame = current_frame(frames)
          until frame.handlers.empty?
            id = frame.handlers.pop || raise(Wardite::EvalError, "missing handler")
            descriptors = frame.function.flat_handlers
            descriptors.fetch(id).clauses.each do |clause|
              if clause.tag_index < 0 || @instance.tags.fetch(clause.tag_index).equal?(value.tag)
                frame.trim_handlers(clause.handler_depth)
                clause.payload_registers.each_with_index do |register, i|
                  frame.registers[register] = value.payload.fetch(i)
                end
                frame.exception_registers[clause.reference_register] = value if clause.reference_register >= 0
                frame.pc = Integer(clause.target_pc)
                return frame
              end
            end
          end
          frames.pop
          pool_at(pools, frame.pool_index).release(frame)
        end
        raise Wardite::UncaughtWasmException, value
      end

      # @rbs frame: Wardite::Efflorescence::Frame
      # @rbs id: Integer
      # @rbs return: Wardite::Efflorescence::ExceptionValue
      def exception_at(frame, id)
        site = frame.function.throw_sites.fetch(id)
        payload = site.payload_registers.map { |register| frame.registers[register] }
        ExceptionValue.new(@instance.tags.fetch(site.tag_index), payload)
      end

      # @rbs pools: Array[Wardite::Efflorescence::FramePool]
      # @rbs index: Integer
      # @rbs return: Wardite::Efflorescence::FramePool
      def pool_at(pools, index)
        pools[index] || raise(Wardite::EvalError, "missing MIR frame pool")
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
        active_frames = [frame]
        execute_flat(frame, pools, active_frames)
      ensure
        active_frames&.each { |active| pool_at(pools, active.pool_index).release(active) }
        if @profiling
          created = 0
          pools.each { |pool| created += pool.created }
          @metrics.frames_created = created
        end
      end

      # @rbs frame: Wardite::Efflorescence::Frame
      # @rbs pools: Array[Wardite::Efflorescence::FramePool]
      # @rbs active_frames: Array[Wardite::Efflorescence::Frame]
      # @rbs return: Integer
      def execute_flat(frame, pools, active_frames)
        frames = active_frames
        registers = frame.registers
        instructions = frame.function.bytecode
        pc = 0
        # Avoid Kernel#loop's StopIteration handler in the native hot loop.
        while true
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
            pc = Integer(frame.pc)
            next
          when 12 # Opcode::TRAP
            raise Wardite::Unreachable, "unreachable op"
          when 23 # Opcode::I32_EQ
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(23, registers[b], registers[c])
          when 24 # Opcode::I32_NE
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(24, registers[b], registers[c])
          when 25 # Opcode::I32_LTS
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(25, registers[b], registers[c])
          when 26 # Opcode::I32_LTU
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(26, registers[b], registers[c])
          when 27 # Opcode::I32_GTS
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(27, registers[b], registers[c])
          when 28 # Opcode::I32_GTU
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(28, registers[b], registers[c])
          when 29 # Opcode::I32_LES
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(29, registers[b], registers[c])
          when 30 # Opcode::I32_LEU
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(30, registers[b], registers[c])
          when 31 # Opcode::I32_GES
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(31, registers[b], registers[c])
          when 32 # Opcode::I32_GEU
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(32, registers[b], registers[c])
          when 33 # Opcode::I32_CLZ
            b = instructions.fetch(pc + 2)
            registers[a] = calculate(33, registers[b], 0)
          when 34 # Opcode::I32_CTZ
            b = instructions.fetch(pc + 2)
            registers[a] = calculate(34, registers[b], 0)
          when 35 # Opcode::I32_POPCNT
            b = instructions.fetch(pc + 2)
            registers[a] = calculate(35, registers[b], 0)
          when 36 # Opcode::I32_DIV_S
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(36, registers[b], registers[c])
          when 37 # Opcode::I32_DIV_U
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(37, registers[b], registers[c])
          when 38 # Opcode::I32_REM_S
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(38, registers[b], registers[c])
          when 39 # Opcode::I32_REM_U
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(39, registers[b], registers[c])
          when 40 # Opcode::I32_AND
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(40, registers[b], registers[c])
          when 41 # Opcode::I32_OR
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(41, registers[b], registers[c])
          when 42 # Opcode::I32_SHR_S
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(42, registers[b], registers[c])
          when 43 # Opcode::I32_ROTL
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(43, registers[b], registers[c])
          when 44 # Opcode::I32_ROTR
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = calculate(44, registers[b], registers[c])
          when 45 # Opcode::I32_EXTEND8_S
            b = instructions.fetch(pc + 2)
            registers[a] = calculate(45, registers[b], 0)
          when 46 # Opcode::I32_EXTEND16_S
            b = instructions.fetch(pc + 2)
            registers[a] = calculate(46, registers[b], 0)
          when 47 # Opcode::COPY_REF
            b = instructions.fetch(pc + 2)
            frame.exception_registers[a] = frame.exception_registers[b]
          when 48 # Opcode::EH_ENTER
            frame.handlers << a
          when 49 # Opcode::EH_TRIM
            frame.trim_handlers(a)
          when 50 # Opcode::THROW
            value_ref = exception_at(frame, a)
            frame = propagate(value_ref, frames, pools)
            registers = frame.registers
            instructions = frame.function.bytecode
            pc = Integer(frame.pc)
            next
          when 51 # Opcode::THROW_REF
            value_ref = frame.exception_registers[a]
            raise Wardite::EvalError, "throw_ref null" unless value_ref
            frame = propagate(value_ref, frames, pools)
            registers = frame.registers
            instructions = frame.function.bytecode
            pc = Integer(frame.pc)
            next
          when 52 # Opcode::GLOBAL_GET
            b = instructions.fetch(pc + 2)
            registers[a] = @store_access.global_get(b)
          when 53 # Opcode::GLOBAL_SET
            b = instructions.fetch(pc + 2)
            @store_access.global_set(a, registers[b])
          when 54 # Opcode::I32_LOAD
            raise UnsupportedFeature, "Efflorescence: I32_LOAD is not implemented yet"
          when 55 # Opcode::I32_LOAD8_S
            raise UnsupportedFeature, "Efflorescence: I32_LOAD8_S is not implemented yet"
          when 56 # Opcode::I32_LOAD8_U
            raise UnsupportedFeature, "Efflorescence: I32_LOAD8_U is not implemented yet"
          when 57 # Opcode::I32_LOAD16_S
            raise UnsupportedFeature, "Efflorescence: I32_LOAD16_S is not implemented yet"
          when 58 # Opcode::I32_LOAD16_U
            raise UnsupportedFeature, "Efflorescence: I32_LOAD16_U is not implemented yet"
          when 59 # Opcode::I32_STORE
            raise UnsupportedFeature, "Efflorescence: I32_STORE is not implemented yet"
          when 60 # Opcode::I32_STORE8
            raise UnsupportedFeature, "Efflorescence: I32_STORE8 is not implemented yet"
          when 61 # Opcode::I32_STORE16
            raise UnsupportedFeature, "Efflorescence: I32_STORE16 is not implemented yet"
          when 62 # Opcode::MEMORY_SIZE
            raise UnsupportedFeature, "Efflorescence: MEMORY_SIZE is not implemented yet"
          when 63 # Opcode::MEMORY_GROW
            raise UnsupportedFeature, "Efflorescence: MEMORY_GROW is not implemented yet"
          when 64 # Opcode::MEMORY_INIT
            raise UnsupportedFeature, "Efflorescence: MEMORY_INIT is not implemented yet"
          when 65 # Opcode::MEMORY_COPY
            raise UnsupportedFeature, "Efflorescence: MEMORY_COPY is not implemented yet"
          when 66 # Opcode::MEMORY_FILL
            raise UnsupportedFeature, "Efflorescence: MEMORY_FILL is not implemented yet"
          when 22 # Opcode::PROFILE
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            @metrics.record(a, b, c)
          else
            raise Wardite::EvalError, "Efflorescence: invalid MIR opcode #{opcode}"
          end
          pc += Lowerer::WIDTH
        end
        # Steep treats while as possibly nil; execution always returns or raises.
        raise Wardite::EvalError, "Efflorescence: MIR execution ended without RETURN"
      end
    end
  end
end
