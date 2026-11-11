# frozen_string_literal: true
# rbs_inline: enabled

require "digest"
require "fileutils"
require "securerandom"

module Wardite
  module Efflorescence
    # Local, opt-in cache of the verified output of Lowerer. Bump CODE_VERSION
    # when the generated code or its interpretation changes, including opcodes,
    # optimizer/validator fixes, and changes to the metadata used by the VM.
    class MIRCache
      MAGIC = "WARDMIR\0".b
      FORMAT_VERSION = 1
      CODE_VERSION = 1
      DIGEST_SIZE = 32
      MAX_BYTES = 256 * 1024 * 1024
      TYPES = %i[i32 i64 f32 f64 exnref].freeze
      TYPE_IDS = TYPES.each_with_index.to_h.freeze
      USES_I64 = 1
      USES_FLOAT = 2
      USES_EH = 4
      USES_STORE = 8
      USES_DYNAMIC_CALLS = 16
      FUNCTION_FLAGS = USES_I64 | USES_FLOAT | USES_EH | USES_STORE | USES_DYNAMIC_CALLS

      class Invalid < StandardError; end

      # All records are little-endian. Vectors carry a nonnegative 32-bit element count.
      # A record count is bounded by the bytes still available to decode it.
      class Reader
        # @rbs bytes: String
        def initialize(bytes)
          @bytes = bytes
          @offset = 0
        end

        # @rbs length: Integer
        # @rbs return: String
        def bytes(length)
          ensure_bytes(length)
          result = @bytes.byteslice(@offset, length) || raise(Invalid)
          @offset += length
          result
        end

        # @rbs return: Integer
        def integer
          ensure_bytes(4)
          result = @bytes.unpack1("l<", offset: @offset) #: Integer
          @offset += 4
          result
        end

        # @rbs width: Integer
        # @rbs return: Integer
        def count(width)
          length = integer
          raise Invalid if length < 0
          ensure_bytes(length * width)
          length
        end

        # @rbs format: String
        # @rbs width: Integer
        # @rbs return: Array[Integer]
        def vector(format, width)
          length = count(width)
          result = @bytes.unpack("#{format}#{length}", offset: @offset) #: Array[Integer]
          @offset += length * width
          result
        end

        # @rbs return: Array[Symbol]
        def types
          vector("C", 1).map { |id| TYPES[id] || raise(Invalid) }
        end

        # @rbs return: void
        def finish
          raise Invalid unless @offset == @bytes.bytesize
        end

        private

        # @rbs length: Integer
        # @rbs return: void
        def ensure_bytes(length)
          raise Invalid if length > @bytes.bytesize - @offset
        end
      end

      class Writer
        attr_reader :bytes #: String

        def initialize
          @bytes = +"".b
        end

        # @rbs *values: Integer
        # @rbs return: void
        def integers(*values)
          @bytes << values.pack("l<*")
        end

        # @rbs values: Array[Integer]
        # @rbs format: String
        # @rbs return: void
        def vector(values, format = "l<")
          integers(values.size)
          @bytes << values.pack("#{format}*")
        end

        # @rbs types: Array[Symbol]
        # @rbs return: void
        def types(types)
          vector(types.map { |type| TYPE_IDS.fetch(type) }, "C")
        end

        # @rbs function: Function
        # @rbs return: void
        def function(function)
          flags = 0
          flags |= USES_I64 if function.uses_i64
          flags |= USES_FLOAT if function.uses_float
          flags |= USES_EH if function.uses_eh
          flags |= USES_STORE if function.uses_store
          flags |= USES_DYNAMIC_CALLS if function.uses_dynamic_calls
          integers(flags)
          types(function.register_types)
          vector(function.initial_registers, "q<")
          vector(function.constant_registers)
          vector(function.bytecode, "q<")
          call_count = function.call_site_count
          integers(call_count)
          call_count.times do |index|
            site = function.call_site(index)
            integers(site.pool_index)
            vector(site.arguments)
          end
          integers(function.dynamic_sites.size)
          function.dynamic_sites.each do |site|
            integers(site.host_index, site.table_index)
            types(site.parameter_types)
            types(site.result_types)
            vector(site.arguments)
          end
          integers(function.memory_sites.size)
          function.memory_sites.each do |site|
            integers(site.memory_index, site.source_memory_index, site.data_index)
            vector(site.sources)
          end
          integers(function.throw_sites.size)
          function.throw_sites.each do |site|
            integers(site.tag_index)
            vector(site.payload_registers)
          end
          integers(function.flat_handlers.size)
          function.flat_handlers.each do |handler|
            integers(handler.clauses.size)
            handler.clauses.each do |clause|
              integers(clause.tag_index, clause.reference_register, clause.target_pc, clause.handler_depth)
              vector(clause.payload_registers)
            end
          end
        end
      end

      class Decoder
        include Opcode

        # Reuse the semantic register roles for fixed operands. Lowering
        # moves direct call arguments into a side table and leaves optional
        # destinations and return operands to be checked against signatures.
        REGISTER_MASKS = Opcode::NAMES.each_index.map do |opcode|
          next 0 if opcode == CALL || opcode == RETURN

          instruction = Instruction.new([opcode, 0, 0, 0])
          positions = Opcode.read_positions(instruction)
          positions << 1 if Opcode.destination(instruction) >= 0 && !Opcode.dynamic_call?(opcode)
          positions.reduce(0) { |mask, position| mask | (1 << (position - 1)) }
        end.freeze #: Array[Integer]

        EXTRA_OPERANDS = Opcode::NAMES.each_index.map do |opcode|
          case opcode
          when BR then :branch
          when BR_IF, BR_IF_ZERO then :conditional
          when CALL then :call
          when CALL_HOST, CALL_INDIRECT then :dynamic_call
          when RETURN then :return
          when EH_ENTER then :handler
          when EH_TRIM then :depth
          when THROW then :throw
          when MEMORY_INIT, MEMORY_COPY, MEMORY_FILL then :bulk
          when MEMORY_SIZE, MEMORY_GROW then :memory
          when GLOBAL_GET, I64_GLOBAL_GET, F32_GLOBAL_GET, F64_GLOBAL_GET then :global_get
          when GLOBAL_SET, I64_GLOBAL_SET, F32_GLOBAL_SET, F64_GLOBAL_SET then :global_set
          when I32_LOAD..I32_STORE16, I64_LOAD..I64_STORE32, F32_LOAD..F64_STORE then :address
          when I32_ADD_IMM..I32_SHR_U_IMM then :immediate
          when I32_XOR_SHR_U_IMM, I32_XOR_SHL_IMM then :shift
          end
        end.freeze #: Array[Symbol?]

        # @rbs reader: Reader
        # @rbs instance: Wardite::Instance
        # @rbs linked: IR
        def initialize(reader, instance, linked)
          @reader = reader
          @instance = instance
          @linked = linked
          @defined_count = linked.entries.size - linked.hosts.size
          @data_count = instance.store.data_segments.size
          @has_memory = !instance.store.memories.empty?
          @table = instance.store.tables[0] #: Wardite::Table?
          @signatures = instance.types.to_h { |type| [[type.callsig, type.retsig], true] } #: Hash[[Array[Symbol], Array[Symbol]], bool]
        end

        # @rbs return: IR
        def decode
          raise Invalid unless @reader.count(4) == @defined_count

          functions = [] #: Array[Function]
          call_records = [] #: Array[Array[[Integer, Array[Integer]]]]
          @instance.store.funcs.each_with_index do |wasm, index|
            next unless wasm.is_a?(Wardite::WasmFunction)

            function = read_function(wasm, index, functions.size)
            functions << function
            call_records << read_sites(function)
          end
          @reader.finish

          functions.zip(call_records).each do |function, records|
            raise Invalid unless records
            records.each do |index, arguments|
              callee = functions.fetch(index)
              check_arguments(function, arguments, callee.parameter_types)
              function.add_call_site(CallSite.new(callee, arguments))
            end
            check_code(function)
          end
          IR.new(functions, entries: @linked.entries, hosts: @linked.hosts)
        end

        private

        # @rbs wasm: Wardite::WasmFunction
        # @rbs index: Integer
        # @rbs pool_index: Integer
        # @rbs return: Function
        def read_function(wasm, index, pool_index)
          flags = @reader.integer
          raise Invalid unless flags.between?(0, FUNCTION_FLAGS)

          types = @reader.types
          first_local = wasm.callsig.size
          first_temporary = first_local + wasm.locals_count.sum
          raise Invalid unless first_temporary <= types.size && types.take(first_local) == wasm.callsig

          local_index = first_local
          wasm.locals_type.zip(wasm.locals_count).each do |type, count|
            raise Invalid unless count && types.slice(local_index, count)&.all? { |actual| actual == type }
            local_index += count
          end
          locals = types.slice(first_local, first_temporary - first_local) || raise(Invalid)
          function = Function.new(index, wasm.callsig, wasm.retsig, locals.size, local_types: locals, pool_index: pool_index)
          function.uses_i64 = (flags & USES_I64) != 0
          function.uses_float = (flags & USES_FLOAT) != 0
          function.uses_eh = (flags & USES_EH) != 0
          function.uses_store = (flags & USES_STORE) != 0
          function.uses_dynamic_calls = (flags & USES_DYNAMIC_CALLS) != 0
          raise Invalid if !function.uses_eh && types.include?(:exnref)

          initial = @reader.vector("q<", 8)
          raise Invalid unless initial.size == types.size
          constants = @reader.vector("l<", 4)
          previous = first_temporary - 1
          constants.each do |slot|
            raise Invalid unless slot > previous && slot < types.size
            previous = slot
          end
          constant_index = 0
          initial.each_with_index do |bits, slot|
            if slot == constants[constant_index]
              type = types.fetch(slot)
              raise Invalid if type == :exnref || ((type == :i32 || type == :f32) && !bits.between?(0, 0xffffffff))
              constant_index += 1
            else
              raise Invalid unless bits.zero?
            end
          end
          function.register_types.replace(types)
          function.initial_registers.replace(initial)
          function.constant_registers.replace(constants)

          code = @reader.vector("q<", 8)
          raise Invalid if code.empty? || code.size % Lowerer::WIDTH != 0
          # Keep the lowerer's integer array representation in Spinel.
          function.bytecode.replace(code)
          function
        end

        # @rbs function: Function
        # @rbs return: Array[[Integer, Array[Integer]]]
        def read_sites(function)
          calls = Array.new(@reader.count(8)) do
            index = @reader.integer
            raise Invalid unless index.between?(0, @defined_count - 1)
            [index, @reader.vector("l<", 4)]
          end #: Array[[Integer, Array[Integer]]]
          @reader.count(20).times { function.dynamic_sites << read_dynamic_site(function) }
          @reader.count(16).times { function.memory_sites << read_memory_site(function) }
          @reader.count(8).times do
            tag = @reader.integer
            registers = @reader.vector("l<", 4)
            check_arguments(function, registers, tag_types(tag))
            function.throw_sites << ThrowSite.new(tag, registers)
          end
          handler_count = @reader.count(4)
          handler_count.times do
            clauses = Array.new(@reader.count(20)) { read_catch(function, handler_count) }
            function.flat_handlers << HandlerDescriptor.new(clauses)
          end
          calls
        end

        # @rbs function: Function
        # @rbs return: DynamicCallSite
        def read_dynamic_site(function)
          host_index = @reader.integer
          table_index = @reader.integer
          params = @reader.types
          results = @reader.types
          arguments = @reader.vector("l<", 4)
          if host_index == -1
            raise Invalid unless table_index == 0 && @table&.type == :funcref &&
              @signatures.key?([params, results]) && results.size <= 1 &&
              (params + results).all? { |type| FunctionEntry.numeric_type?(type) }
          else
            host = at(@linked.hosts, host_index)
            raise Invalid unless table_index == -1 && params == host.entry.parameter_types && results == host.entry.result_types
          end
          check_arguments(function, arguments, params)
          DynamicCallSite.new(host_index, arguments, params, results, table_index: table_index)
        end

        # @rbs function: Function
        # @rbs return: MemorySite
        def read_memory_site(function)
          memory = @reader.integer
          source = @reader.integer
          data = @reader.integer
          registers = @reader.vector("l<", 4)
          raise Invalid unless @has_memory && memory == 0 && source == 0 && data.between?(-1, @data_count - 1)
          check_arguments(function, registers, [:i32, :i32, :i32])
          MemorySite.new(registers, memory_index: memory, source_memory_index: source, data_index: data)
        end

        # @rbs function: Function
        # @rbs handler_count: Integer
        # @rbs return: CatchTarget
        def read_catch(function, handler_count)
          tag = @reader.integer
          reference = @reader.integer
          pc = @reader.integer
          depth = @reader.integer
          registers = @reader.vector("l<", 4)
          check_arguments(function, registers, tag == -1 ? [] : tag_types(tag))
          raise Invalid unless reference == -1 || at(function.register_types, reference) == :exnref
          raise Invalid unless depth.between?(0, handler_count - 1)
          check_target(pc, function.bytecode.size)
          CatchTarget.new(tag, registers, reference, pc, depth)
        end

        # @rbs function: Function
        # @rbs return: void
        def check_code(function)
          code = function.bytecode
          register_count = function.register_count
          pc = 0
          while pc < code.size
            opcode, a, b, c = code[pc], code[pc + 1], code[pc + 2], code[pc + 3]
            raise Invalid unless opcode.between?(0, REGISTER_MASKS.size - 1) && opcode != PROFILE
            mask = REGISTER_MASKS.fetch(opcode)
            raise Invalid if (mask[0] == 1 && !a.between?(0, register_count - 1)) ||
              (mask[1] == 1 && !b.between?(0, register_count - 1)) ||
              (mask[2] == 1 && !c.between?(0, register_count - 1))

            case EXTRA_OPERANDS[opcode]
            when :branch then check_target(a, code.size)
            when :conditional then check_target(b, code.size)
            when :call
              raise Invalid unless b.between?(0, function.call_site_count - 1)
              site = function.call_site(b)
              expected = site.arguments.size == 1 ? site.arguments.fetch(0) : -1
              raise Invalid unless c == expected
              check_result(function, a, site.callee.result_types)
            when :dynamic_call
              site = at(function.dynamic_sites, b)
              raise Invalid unless opcode == CALL_HOST ? (site.host_index >= 0 && c == 0) : site.table_index == 0
              check_result(function, a, site.result_types)
            when :return then check_result(function, a, function.result_types)
            when :handler then at(function.flat_handlers, a)
            when :depth then raise Invalid unless a.between?(0, function.flat_handlers.size)
            when :throw then at(function.throw_sites, a)
            when :bulk
              site = at(function.memory_sites, a)
              raise Invalid unless opcode == MEMORY_INIT ? site.data_index >= 0 : site.data_index == -1
            when :global_get then at(@instance.store.globals, b)
            when :global_set then at(@instance.store.globals, a)
            when :address then raise Invalid unless @has_memory && c.between?(0, 0xffffffff)
            when :memory then raise Invalid unless @has_memory
            when :immediate then raise Invalid unless c.between?(0, 0xffffffff)
            when :shift then raise Invalid unless c.between?(0, 31)
            end
            pc += Lowerer::WIDTH
          end
        end

        # @rbs tag: Integer
        # @rbs return: Array[Symbol]
        def tag_types(tag)
          at(@instance.tags, tag).parameter_types
        end

        # @rbs function: Function
        # @rbs registers: Array[Integer]
        # @rbs types: Array[Symbol]
        # @rbs return: void
        def check_arguments(function, registers, types)
          raise Invalid unless registers.size == types.size
          registers.each_with_index do |slot, index|
            raise Invalid unless at(function.register_types, slot) == types.fetch(index)
          end
        end

        # @rbs function: Function
        # @rbs slot: Integer
        # @rbs types: Array[Symbol]
        # @rbs return: void
        def check_result(function, slot, types)
          raise Invalid unless types.empty? ? slot == -1 : at(function.register_types, slot) == types.fetch(0)
        end

        # @rbs target: Integer
        # @rbs limit: Integer
        # @rbs return: void
        def check_target(target, limit)
          raise Invalid unless target.between?(0, limit - 1) && target % Lowerer::WIDTH == 0
        end

        # @rbs [T] (Array[T] values, Integer index) -> T
        def at(values, index)
          raise Invalid unless index.between?(0, values.size - 1)
          values.fetch(index)
        end
      end

      # @rbs directory: String
      # @rbs wasm: String
      # @rbs configuration: Configuration
      def initialize(directory, wasm, configuration)
        versions = [FORMAT_VERSION, CODE_VERSION].pack("L<2")
        disabled = configuration.disabled.uniq.sort.join(",")
        key_data = versions + Digest::SHA256.digest(wasm) + disabled
        key_data = "spinel\0".b + key_data if RUBY_ENGINE == "spinel"
        key = Digest::SHA256.digest(key_data)
        @header = MAGIC + versions + key
        @directory = File.expand_path(directory)
        @path = File.join(@directory, "#{key.unpack1("H*")}.mir2")
      end

      # @rbs instance: Wardite::Instance
      # @rbs linked: IR
      # @rbs return: IR?
      def read(instance, linked)
        contents = File.open(@path, File::RDONLY | File::NONBLOCK) do |file|
          stat = file.stat
          raise Invalid unless stat.file? && stat.size <= MAX_BYTES
          file.binmode
          contents = file.read(stat.size) || raise(Invalid)
          raise Invalid unless file.eof?
          contents
        end
        prefix_size = @header.bytesize + DIGEST_SIZE
        raise Invalid unless contents.bytesize.between?(prefix_size, MAX_BYTES) && contents.start_with?(@header)

        payload = contents.byteslice(prefix_size..) || raise(Invalid)
        raise Invalid unless contents.byteslice(@header.bytesize, DIGEST_SIZE) == Digest::SHA256.digest(payload)

        reader = Reader.new(payload)
        raise Invalid unless reader.bytes(reader.count(1)) == encode_layout(instance, linked.entries)
        ir = Decoder.new(reader, instance, linked).decode
        $stderr.puts "MIR2 cache hit: #{@path}" if ENV["WARITE_TRACE"]
        ir
      rescue SystemCallError, IOError, Invalid
        $stderr.puts "MIR2 cache miss: #{@path}" if ENV["WARITE_TRACE"]
        nil
      end

      # @rbs instance: Wardite::Instance
      # @rbs ir: IR
      # @rbs return: void
      def write(instance, ir)
        FileUtils.mkdir_p(@directory)
        writer = Writer.new
        layout = encode_layout(instance, ir.entries)
        writer.integers(layout.bytesize)
        writer.bytes << layout
        writer.integers(ir.functions.size)
        ir.functions.each do |function|
          writer.function(function)
          return if @header.bytesize + DIGEST_SIZE + writer.bytes.bytesize > MAX_BYTES
        end
        publish(writer.bytes)
      rescue SystemCallError, IOError
        # Cache I/O is optional once the normal build has succeeded.
        nil
      end

      private

      # Exclusive creation protects a concurrent writer's temporary file.
      # Close the file before publishing it under the cache key.
      # @rbs payload: String
      # @rbs return: void
      def publish(payload)
        path = File.join(@directory, ".wardite-#{SecureRandom.hex(16)}.tmp")
        file = File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
        begin
          file.binmode
          file.write(@header)
          file.write(Digest::SHA256.digest(payload))
          file.write(payload)
          file.close
          File.rename(path, @path)
        ensure
          file.close unless file.closed?
          File.unlink(path) if File.exist?(path)
        end
      end

      # Include the module's import identities, and every function's signature
      # and index mapping. The live entries and hosts are always linked afresh.
      # @rbs instance: Wardite::Instance
      # @rbs entries: Array[FunctionEntry]
      # @rbs return: String
      def encode_layout(instance, entries)
        writer = Writer.new
        imports = instance.import_section.imports
        writer.integers(imports.size, entries.size)
        imports.each do |import|
          writer.integers(import.module_name.bytesize, import.name.bytesize)
          writer.bytes << import.module_name.b << import.name.b
        end
        entries.each do |entry|
          writer.integers(entry.defined_index, entry.host_index)
          writer.types(entry.parameter_types)
          writer.types(entry.result_types)
        end
        writer.bytes
      end
    end
  end
end
