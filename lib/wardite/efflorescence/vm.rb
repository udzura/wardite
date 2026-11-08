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
        @function_indices = {} #: Hash[Integer, Integer]
        # Retain the original objects so IDs stay valid even if a host edits
        # Store.funcs. Spinel cannot use an identity Hash for these objects.
        @indirect_functions = [] #: Array[Wardite::WasmFunction | Wardite::ExternalFunction]
        unless instance.store.tables.empty?
          @indirect_functions = instance.store.funcs.dup
          @indirect_functions.each_with_index { |function, index| @function_indices[function.object_id] = index }
        end
        configuration = Configuration.new(disabled_optimizations)
        @reuse_frames = configuration.enabled?(:frames)
        @profiling = profile
        @metrics = Metrics.new
        @semantic_ir = Translator.new(instance).translate
        @optimized_ir = Optimizer.new(configuration).optimize(@semantic_ir)
        @optimized_ir.functions.each { |function| RegisterValidation.new.validate(function, @optimized_ir) }
        @ir = profile ? Instrumentation.new.instrument(@optimized_ir) : @optimized_ir
        Lowerer.new.compile(@ir)
        start = instance.start_section
        if start
          entry = @ir.entry_at(start.func_index)
          unless entry.parameter_types.empty? && entry.result_types.empty?
            raise Wardite::LoadError, "start function must have no parameters or results"
          end
          execute(entry, [])
        end
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
      # @rbs return: (Wardite::I32 | Wardite::I64)?
      def call(name, arguments)
        entry = export_entry(name)
        result = execute_public(entry, arguments)
        return nil if result.nil?
        entry.result_types[0] == :i64 ? Wardite::I64(result) : Wardite::I32.new(result)
      end

      # i32 results are unsigned and i64 results are signed.
      # @rbs name: String|Symbol
      # @rbs arguments: Array[Object]
      # @rbs return: Integer?
      def call_unboxed(name, arguments)
        execute_public(export_entry(name), arguments)
      end

      # @rbs name: Symbol
      # @rbs *arguments: Object
      # @rbs return: (Wardite::I32 | Wardite::I64)?
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

      # @rbs name: String|Symbol
      # @rbs return: Wardite::Efflorescence::FunctionEntry
      def export_entry(name)
        export = @instance.export_section.exports[name.to_s]
        raise ::NoMethodError, "function #{name} not found" unless export
        raise ::NoMethodError, "#{name} is not a function" unless export.kind == 0
        @ir.entry_at(export.index)
      end

      # @rbs entry: Wardite::Efflorescence::FunctionEntry
      # @rbs arguments: Array[Object]
      # @rbs return: Integer?
      def execute_public(entry, arguments)
        unless arguments.size == entry.parameter_types.size
          raise Wardite::ArgumentError, "unmatch arg size"
        end
        values = [] #: Array[Integer]
        arguments.each_with_index do |value, i|
          type = entry.parameter_types.fetch(i)
          if type == :i64 && value.is_a?(Wardite::I64)
            values << value.value_s
          elsif value.is_a?(Integer)
            values << (type == :i64 ? I64Arithmetic.normalize(value) : value & 0xffffffff)
          else
            raise Wardite::ArgumentError, "type mismatch: #{type}(#{value})"
          end
        end
        execute(entry, values)
      end

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

      # @rbs host_index: Integer
      # @rbs arguments: Array[Integer]
      # @rbs metrics: Wardite::Efflorescence::Metrics
      # @rbs return: Integer?
      # @rbs sources: Array[Integer]?
      def invoke_host(host_index, arguments, metrics, sources = nil)
        host = @ir.hosts[host_index] || raise(Wardite::EvalError, "missing MIR host function")
        metrics.host_calls += 1 if @profiling
        if RUBY_ENGINE != "spinel"
          wasi = host.unboxed_wasi
          return wasi.call(@instance.store, arguments, sources) if wasi
        end
        boxed = [] #: Array[Wardite::wasmValue]
        if sources
          sources.each { |register| boxed << Wardite::I32.new(arguments[register]) }
        else
          arguments.each { |value| boxed << Wardite::I32.new(value) }
        end
        result = host.callable.call(@instance.store, boxed)
        if host.entry.result_types.empty?
          return nil if result.nil?
        elsif result.is_a?(Integer)
          return result & 0xffffffff
        elsif result.is_a?(Wardite::I32)
          return result.value & 0xffffffff
        end
        raise Wardite::EvalError, "host ABI result mismatch for #{host.external.name}"
      end

      # Each public entry owns its frames, pools and counters, including when a
      # host callback re-enters the VM. Store mutations are shared immediately.
      # @rbs entry: Wardite::Efflorescence::FunctionEntry
      # @rbs arguments: Array[Integer]
      # @rbs return: Integer?
      def execute(entry, arguments)
        metrics = @profiling ? Metrics.new : @metrics
        pools = [] #: Array[Wardite::Efflorescence::FramePool]
        active_frames = [] #: Array[Wardite::Efflorescence::Frame]
        return invoke_host(entry.host_index, arguments, metrics) if entry.kind == :host

        @ir.functions.each { |function| pools << FramePool.new(function, @reuse_frames) }
        frame = pool_at(pools, entry.defined_index).acquire(-1)
        active_frames << frame
        metrics.root_defined_entries = 1 if @profiling
        arguments.each_with_index { |value, i| frame.registers[i] = value }
        result = execute_flat(frame, pools, active_frames, metrics)
        entry.result_types.empty? ? nil : result
      ensure
        active_frames.each { |active| pool_at(pools, active.pool_index).release(active) }
        if @profiling
          created = 0
          pools.each { |pool| created += pool.created }
          metrics.frames_created = created
          @metrics = metrics
        end
      end

      # @rbs frame: Wardite::Efflorescence::Frame
      # @rbs site: Wardite::Efflorescence::DynamicCallSite
      # @rbs host_index: Integer
      # @rbs destination: Integer
      # @rbs metrics: Wardite::Efflorescence::Metrics
      # @rbs return: void
      def execute_host_site(frame, site, host_index, destination, metrics)
        registers = frame.registers
        result = invoke_host(host_index, registers, metrics, site.arguments)
        registers[destination] = result if destination >= 0 && result
      end

      # @rbs site: Wardite::Efflorescence::DynamicCallSite
      # @rbs selector: Integer
      # @rbs return: Wardite::Efflorescence::FunctionEntry
      def indirect_entry(site, selector)
        table = @instance.store.tables[site.table_index]
        raise Wardite::EvalError, "call_indirect requires funcref table 0" unless table && table.type == :funcref
        index = selector & 0xffffffff
        raise Wardite::EvalError, "call_indirect table index out of bounds: #{index}" if index >= table.current
        function = table.refs[index]
        raise Wardite::EvalError, "call_indirect null reference" if function.nil?
        function_index = @function_indices[function.object_id]
        unless function_index && @indirect_functions[function_index].equal?(function)
          raise Wardite::EvalError, "call_indirect unknown function reference"
        end
        entry = @ir.entry_at(function_index)
        unless entry.parameter_types == site.parameter_types && entry.result_types == site.result_types
          raise Wardite::EvalError, "call_indirect function type mismatch"
        end
        entry
      end

      # @rbs frame: Wardite::Efflorescence::Frame
      # @rbs site_id: Integer
      # @rbs destination: Integer
      # @rbs metrics: Wardite::Efflorescence::Metrics
      # @rbs return: void
      def execute_direct_host(frame, site_id, destination, metrics)
        site = frame.function.dynamic_site(site_id)
        execute_host_site(frame, site, site.host_index, destination, metrics)
      end

      # Keep table resolution and the additional call locals off the hot path.
      # @rbs frame: Wardite::Efflorescence::Frame
      # @rbs pools: Array[Wardite::Efflorescence::FramePool]
      # @rbs frames: Array[Wardite::Efflorescence::Frame]
      # @rbs destination: Integer
      # @rbs site_id: Integer
      # @rbs selector: Integer
      # @rbs metrics: Wardite::Efflorescence::Metrics
      # @rbs return: Wardite::Efflorescence::Frame
      def execute_indirect(frame, pools, frames, destination, site_id, selector, metrics)
        site = frame.function.dynamic_site(site_id)
        registers = frame.registers
        entry = indirect_entry(site, registers[selector])
        if entry.kind == :host
          execute_host_site(frame, site, entry.host_index, destination, metrics)
          frame
        else
          next_frame = pool_at(pools, entry.defined_index).acquire(destination)
          frames << next_frame
          target = next_frame.registers
          site.arguments.each_with_index { |register, i| target[i] = registers[register] }
          metrics.enter_indirect_defined(site.arguments.size) if @profiling
          next_frame
        end
      end

      # @rbs frame: Wardite::Efflorescence::Frame
      # @rbs pools: Array[Wardite::Efflorescence::FramePool]
      # @rbs active_frames: Array[Wardite::Efflorescence::Frame]
      # @rbs return: Integer
      # @rbs metrics: Wardite::Efflorescence::Metrics
      def execute_flat(frame, pools, active_frames, metrics)
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
          when 67 # Opcode::CALL_HOST
            execute_direct_host(frame, instructions.fetch(pc + 2), a, metrics)
          when 68 # Opcode::CALL_INDIRECT
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            frame.pc = pc + Lowerer::WIDTH
            frame = execute_indirect(frame, pools, frames, a, b, c, metrics)
            registers = frame.registers
            instructions = frame.function.bytecode
            pc = Integer(frame.pc)
            next
          when 11 # Opcode::RETURN
            # Verified RETURN reads an initialized integer. Keep its native type
            # separate from the nullable array reads used by the ALU cases.
            return_value = a < 0 ? 0 : Integer(registers[a])
            destination = frame.return_register
            frames.pop
            pool = pools[frame.pool_index]
            raise Wardite::EvalError, "missing MIR frame pool" unless pool
            pool.release(frame)
            return return_value if frames.empty?
            frame = current_frame(frames)
            registers = frame.registers
            registers[destination] = return_value if destination >= 0
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
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = @store_access.load(registers[b], c, 4, false)
          when 55 # Opcode::I32_LOAD8_S
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = @store_access.load(registers[b], c, 1, true)
          when 56 # Opcode::I32_LOAD8_U
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = @store_access.load(registers[b], c, 1, false)
          when 57 # Opcode::I32_LOAD16_S
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = @store_access.load(registers[b], c, 2, true)
          when 58 # Opcode::I32_LOAD16_U
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = @store_access.load(registers[b], c, 2, false)
          when 59 # Opcode::I32_STORE
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            @store_access.store(registers[b], c, 4, registers[a])
          when 60 # Opcode::I32_STORE8
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            @store_access.store(registers[b], c, 1, registers[a])
          when 61 # Opcode::I32_STORE16
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            @store_access.store(registers[b], c, 2, registers[a])
          when 62 # Opcode::MEMORY_SIZE
            registers[a] = @store_access.size
          when 63 # Opcode::MEMORY_GROW
            b = instructions.fetch(pc + 2)
            registers[a] = @store_access.grow(registers[b])
          when 64 # Opcode::MEMORY_INIT
            @store_access.bulk(64, frame.function.memory_site(a), registers)
          when 65 # Opcode::MEMORY_COPY
            @store_access.bulk(65, frame.function.memory_site(a), registers)
          when 66 # Opcode::MEMORY_FILL
            @store_access.bulk(66, frame.function.memory_site(a), registers)
          when 69 # Opcode::I64_EQZ
            b = instructions.fetch(pc + 2)
            registers[a] = I64Arithmetic.calculate(69, registers[b], 0)
          when 70 # Opcode::I32_WRAP_I64
            b = instructions.fetch(pc + 2)
            registers[a] = I64Arithmetic.calculate(70, registers[b], 0)
          when 71 # Opcode::I64_EQ
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(71, registers[b], registers[c])
          when 72 # Opcode::I64_NE
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(72, registers[b], registers[c])
          when 73 # Opcode::I64_LTS
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(73, registers[b], registers[c])
          when 74 # Opcode::I64_LTU
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(74, registers[b], registers[c])
          when 75 # Opcode::I64_GTS
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(75, registers[b], registers[c])
          when 76 # Opcode::I64_GTU
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(76, registers[b], registers[c])
          when 77 # Opcode::I64_LES
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(77, registers[b], registers[c])
          when 78 # Opcode::I64_LEU
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(78, registers[b], registers[c])
          when 79 # Opcode::I64_GES
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(79, registers[b], registers[c])
          when 80 # Opcode::I64_GEU
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(80, registers[b], registers[c])
          when 81 # Opcode::I64_CLZ
            b = instructions.fetch(pc + 2)
            registers[a] = I64Arithmetic.calculate(81, registers[b], 0)
          when 82 # Opcode::I64_CTZ
            b = instructions.fetch(pc + 2)
            registers[a] = I64Arithmetic.calculate(82, registers[b], 0)
          when 83 # Opcode::I64_POPCNT
            b = instructions.fetch(pc + 2)
            registers[a] = I64Arithmetic.calculate(83, registers[b], 0)
          when 84 # Opcode::I64_EXTEND8_S
            b = instructions.fetch(pc + 2)
            registers[a] = I64Arithmetic.calculate(84, registers[b], 0)
          when 85 # Opcode::I64_EXTEND16_S
            b = instructions.fetch(pc + 2)
            registers[a] = I64Arithmetic.calculate(85, registers[b], 0)
          when 86 # Opcode::I64_EXTEND32_S
            b = instructions.fetch(pc + 2)
            registers[a] = I64Arithmetic.calculate(86, registers[b], 0)
          when 87 # Opcode::I64_EXTEND_I32_S
            b = instructions.fetch(pc + 2)
            registers[a] = I64Arithmetic.calculate(87, registers[b], 0)
          when 88 # Opcode::I64_EXTEND_I32_U
            b = instructions.fetch(pc + 2)
            registers[a] = I64Arithmetic.calculate(88, registers[b], 0)
          when 89 # Opcode::I64_AND
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(89, registers[b], registers[c])
          when 90 # Opcode::I64_OR
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(90, registers[b], registers[c])
          when 91 # Opcode::I64_XOR
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(91, registers[b], registers[c])
          when 92 # Opcode::I64_SHL
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(92, registers[b], registers[c])
          when 93 # Opcode::I64_SHR_S
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(93, registers[b], registers[c])
          when 94 # Opcode::I64_SHR_U
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(94, registers[b], registers[c])
          when 95 # Opcode::I64_ROTL
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(95, registers[b], registers[c])
          when 96 # Opcode::I64_ROTR
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            registers[a] = I64Arithmetic.calculate(96, registers[b], registers[c])
          when 22 # Opcode::PROFILE
            b = instructions.fetch(pc + 2)
            c = instructions.fetch(pc + 3)
            metrics.record(a, b, c)
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
