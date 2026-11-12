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
      FORMAT_VERSION = 3
      CODE_VERSION = 1
      DIGEST_SIZE = 32
      LENGTH_SIZE = 8
      INTEGRITY_SIZE = LENGTH_SIZE + 2 * DIGEST_SIZE
      SAMPLE_EDGE = 64 * 1024
      SAMPLE_STEP = 1024 * 1024
      SAMPLE_BLOCK = 4 * 1024
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

      # Identifies the module, the generated code, and the host build.
      attr_reader :key #: String

      # All records are little-endian. Vectors carry a nonnegative 32-bit element count.
      # A record count is bounded by the bytes still available to decode it.
      class Reader
        attr_reader :offset #: Integer

        # @rbs bytes: String
        # @rbs offset: Integer
        # @rbs length: Integer?
        def initialize(bytes, offset: 0, length: nil)
          @bytes = bytes
          @offset = offset
          @limit = length ? offset + length : bytes.bytesize
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

        # @rbs target: Array[Integer]
        # @rbs format: String
        # @rbs width: Integer
        # @rbs return: void
        def read_into(target, format, width)
          if RUBY_ENGINE == "spinel"
            length = count(width)
            offset = @offset
            limit = offset + length * width
            target.clear
            IO::Buffer.for(@bytes) do |buffer|
              if width == 8
                while offset < limit
                  target << buffer.get_value(:s64, offset)
                  offset += 8
                end
              else
                while offset < limit
                  target << buffer.get_value(:s32, offset)
                  offset += 4
                end
              end
            end
            @offset = limit
          else
            target.replace(vector(format, width))
          end
        end

        # @rbs return: Array[Symbol]
        def types
          vector("C", 1).map { |id| TYPES[id] || raise(Invalid) }
        end

        # @rbs return: void
        def finish
          raise Invalid unless @offset == @limit
        end

        private

        # @rbs length: Integer
        # @rbs return: void
        def ensure_bytes(length)
          raise Invalid if length > @limit - @offset
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

        attr_reader :functions #: Array[Function]

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

        # @rbs payload: String
        # @rbs instance: Wardite::Instance
        # @rbs entries: Array[FunctionEntry]
        def initialize(payload, instance, entries)
          @payload = payload
          @reader = Reader.new(payload)
          @entries = entries
          @bodies = instance.code_section&.func_codes || []
          @tags = instance.tags
          @functions = []
          @offsets = [] #: Array[Integer]
          @lengths = [] #: Array[Integer]
          @import_count = instance.import_section.imports.size
          @defined_count = entries.size - @import_count
          @data_count = instance.data_section&.segments&.size || 0
          @global_count = instance.global_section&.globals&.size || 0
          @has_memory = (instance.memory_section&.limits&.size || 0) > 0
          @table_type = instance.table_section&.table_types&.[](0) #: Symbol?
          @signatures = {} #: Hash[[Array[Symbol], Array[Symbol]], bool]
          types = instance.type_section
          if types
            types.defined_types.each_with_index do |params, index|
              @signatures[[params, types.defined_results.fetch(index)]] = true
            end
          end
        end

        # @rbs layout: String
        # @rbs return: void
        def declare(layout)
          raise Invalid unless @reader.count(8) == @defined_count && @bodies.size == @defined_count
          @defined_count.times do
            @offsets << @reader.integer
            @lengths << @reader.integer
          end
          raise Invalid unless @reader.bytes(@reader.count(1)) == layout

          cursor = @reader.offset
          @defined_count.times do |pool_index|
            offset = @offsets.fetch(pool_index)
            length = @lengths.fetch(pool_index)
            raise Invalid unless offset == cursor && length > 0 && length <= @payload.bytesize - cursor
            cursor += length

            index = @import_count + pool_index
            entry = @entries.fetch(index)
            function = Function.new(index, entry.parameter_types, entry.result_types, 0, pool_index: pool_index)
            function.cache_pending = true
            @functions << function
          end
          raise Invalid unless cursor == @payload.bytesize
        end

        # A failed decode must never expose a partially filled function. Keep
        # the slot unavailable even if a Ruby caller catches the error.
        # @rbs function: Function
        # @rbs return: void
        def restore(function)
          index = function.pool_index
          length = @lengths.fetch(index)
          raise Invalid unless length > 0
          @lengths[index] = 0
          @reader = Reader.new(@payload, offset: @offsets.fetch(index), length: length)
          read_function(@bodies.fetch(index), function)
          read_sites(function, @functions)
          @reader.finish
          check_code(function)
          function.cache_pending = false
        end

        private

        # @rbs body: Wardite::CodeSection::CodeBody
        # @rbs function: Function
        # @rbs return: void
        def read_function(body, function)
          flags = @reader.integer
          raise Invalid unless flags.between?(0, FUNCTION_FLAGS)

          types = @reader.types
          params = function.parameter_types
          first_local = params.size
          function.local_count = body.locals_count.sum
          first_temporary = first_local + function.local_count
          raise Invalid unless first_temporary <= types.size && types.take(first_local) == params

          local_index = first_local
          body.locals_type.each_with_index do |type, index|
            count = body.locals_count.fetch(index)
            raise Invalid unless types.slice(local_index, count)&.all? { |actual| actual == type }
            local_index += count
          end
          function.uses_i64 = (flags & USES_I64) != 0
          function.uses_float = (flags & USES_FLOAT) != 0
          function.uses_eh = (flags & USES_EH) != 0
          function.uses_store = (flags & USES_STORE) != 0
          function.uses_dynamic_calls = (flags & USES_DYNAMIC_CALLS) != 0
          raise Invalid if !function.uses_eh && types.include?(:exnref)

          initial = function.initial_registers
          @reader.read_into(initial, "q<", 8)
          raise Invalid unless initial.size == types.size
          constants = function.constant_registers
          @reader.read_into(constants, "l<", 4)
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

          code = function.bytecode
          @reader.read_into(code, "q<", 8)
          raise Invalid if code.empty? || code.size % Lowerer::WIDTH != 0
        end

        # @rbs function: Function
        # @rbs functions: Array[Function]
        # @rbs return: void
        def read_sites(function, functions)
          @reader.count(8).times do
            index = @reader.integer
            raise Invalid unless index.between?(0, @defined_count - 1)
            callee = functions[index] || raise(Invalid)
            site = CallSite.new(callee, [])
            @reader.read_into(site.arguments, "l<", 4)
            check_arguments(function, site.arguments, callee.parameter_types)
            function.add_call_site(site)
          end
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
        end

        # @rbs function: Function
        # @rbs return: DynamicCallSite
        def read_dynamic_site(function)
          host_index = @reader.integer
          table_index = @reader.integer
          params = @reader.types
          results = @reader.types
          if host_index == -1
            raise Invalid unless table_index == 0 && @table_type == :funcref &&
              @signatures.key?([params, results]) && results.size <= 1 &&
              (params + results).all? { |type| FunctionEntry.numeric_type?(type) }
          else
            raise Invalid unless table_index == -1 && host_index.between?(0, @import_count - 1)
            host = @entries.fetch(host_index)
            raise Invalid unless params == host.parameter_types && results == host.result_types
          end
          site = DynamicCallSite.new(host_index, [], params, results, table_index: table_index)
          @reader.read_into(site.arguments, "l<", 4)
          check_arguments(function, site.arguments, params)
          site
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
            when :global_get then raise Invalid unless b.between?(0, @global_count - 1)
            when :global_set then raise Invalid unless a.between?(0, @global_count - 1)
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
          at(@tags, tag).parameter_types
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
      # @rbs verify: Symbol
      # @rbs eager: bool
      def initialize(directory, wasm, configuration, verify: :checksum, eager: false)
        versions = [FORMAT_VERSION, CODE_VERSION].pack("L<2")
        disabled = configuration.disabled.uniq.sort.join(",")
        key_data = versions + Digest::SHA256.digest(wasm) + disabled
        key_data = "spinel\0".b + key_data if RUBY_ENGINE == "spinel"
        key = Digest::SHA256.digest(key_data)
        @key = key
        @header = MAGIC + versions + key
        @directory = File.expand_path(directory)
        @path = File.join(@directory, "#{key.unpack1("H*")}.mir2")
        @verify = verify
        @eager = eager
        @decoder = nil #: Decoder?
      end

      # Restore against module declarations so a miss can decode and check the
      # Wasm bodies before Store initialization or any host lookup.
      # @rbs instance: Wardite::Instance
      # @rbs return: Array[Function]?
      def read(instance)
        payload = read_verified_payload
        entries = module_entries(instance)
        decoder = Decoder.new(payload, instance, entries)
        decoder.declare(encode_layout(instance, entries))
        if @eager
          decoder.functions.each { |function| decoder.restore(function) }
        else
          @decoder = decoder
        end
        $stderr.puts "MIR2 cache hit: #{@path}" if ENV["WARDITE_TRACE"]
        decoder.functions
      rescue SystemCallError, IOError, Invalid
        $stderr.puts "MIR2 cache miss: #{@path}" if ENV["WARDITE_TRACE"]
        nil
      end

      # @rbs function: Function
      # @rbs return: void
      def restore_function(function)
        return unless function.cache_pending

        decoder = @decoder || raise(Invalid)
        decoder.restore(function)
      rescue Invalid
        raise Wardite::EvalError, "invalid MIR2 function #{function.index} in #{@path}. Delete this cache file and retry."
      end

      # @rbs return: void
      def restore_all
        decoder = @decoder
        return unless decoder

        decoder.functions.each { |function| restore_function(function) }
        @decoder = nil
      end

      # @rbs instance: Wardite::Instance
      # @rbs ir: IR
      # @rbs return: void
      def write(instance, ir)
        FileUtils.mkdir_p(@directory)
        layout = encode_layout(instance, ir.entries)
        table = Writer.new
        table.integers(ir.functions.size)
        records = Writer.new
        offset = 8 + 8 * ir.functions.size + layout.bytesize
        ir.functions.each do |function|
          start = records.bytes.bytesize
          records.function(function)
          table.integers(offset + start, records.bytes.bytesize - start)
          return if @header.bytesize + INTEGRITY_SIZE + offset + records.bytes.bytesize > MAX_BYTES
        end
        table.integers(layout.bytesize)
        payload = table.bytes
        payload << layout
        payload << records.bytes
        length = [payload.bytesize].pack("Q<")
        prefix = @header + length + MIRCache.sample_checksum(payload, length) + Digest::SHA256.digest(payload)
        MIRCache.publish(@directory, @path, prefix, payload)
      rescue SystemCallError, IOError
        # Cache I/O is optional once the normal build has succeeded.
        nil
      end

      private

      # @rbs instance: Wardite::Instance
      # @rbs return: Array[FunctionEntry]
      def module_entries(instance)
        imports = instance.import_section.imports
        types = instance.type_section
        entries = [] #: Array[FunctionEntry]
        imports.each_with_index do |import, index|
          params = types&.defined_types&.[](import.sig_index)
          results = types&.defined_results&.[](import.sig_index)
          raise Invalid unless params && results
          entries << FunctionEntry.new(:host, params, results, -1, index)
        end
        instance.each_defined_function do |params, results, _body|
          entries << FunctionEntry.new(:defined, params, results, entries.size - imports.size, -1)
        end
        entries
      rescue Wardite::LoadError
        # Keep the usual Wasm validation path and its errors on a miss.
        raise Invalid
      end

      # @rbs return: String
      def read_verified_payload
        header_size = @header.bytesize
        prefix_size = header_size + INTEGRITY_SIZE
        contents = MIRCache.read_contents(@path, @header, prefix_size)
        length = [contents.bytesize - prefix_size].pack("Q<")
        raise Invalid unless contents.byteslice(header_size, LENGTH_SIZE) == length

        payload = contents.byteslice(prefix_size..) || raise(Invalid)
        digest_offset = header_size + LENGTH_SIZE
        if @verify == :sha256
          digest_offset += DIGEST_SIZE
          digest = Digest::SHA256.digest(payload)
        else
          digest = MIRCache.sample_checksum(payload, length)
        end
        raise Invalid unless contents.byteslice(digest_offset, DIGEST_SIZE) == digest
        payload
      end

      # @rbs payload: String
      # @rbs length: String
      # @rbs return: String
      def self.sample_checksum(payload, length)
        size = payload.bytesize
        return Digest::SHA256.digest(length + payload) if size <= 2 * SAMPLE_EDGE

        sample = length.dup
        sample << (payload.byteslice(0, SAMPLE_EDGE) || raise(Invalid))
        offset = SAMPLE_STEP
        while offset < size
          sample << (payload.byteslice(offset, SAMPLE_BLOCK) || raise(Invalid))
          offset += SAMPLE_STEP
        end
        sample << (payload.byteslice(size - SAMPLE_EDGE, SAMPLE_EDGE) || raise(Invalid))
        Digest::SHA256.digest(sample)
      end

      # Opening without blocking keeps a FIFO from stalling the start of a run.
      # @rbs path: String
      # @rbs header: String
      # @rbs prefix_size: Integer
      # @rbs return: String
      def self.read_contents(path, header, prefix_size)
        contents = File.open(path, File::RDONLY | File::NONBLOCK) do |file|
          stat = file.stat
          raise Invalid unless stat.file? && stat.size <= MAX_BYTES
          file.binmode
          contents = file.read(stat.size) || raise(Invalid)
          raise Invalid unless file.eof?
          contents
        end
        raise Invalid unless contents.bytesize.between?(prefix_size, MAX_BYTES) && contents.start_with?(header)
        contents
      end

      # Exclusive creation protects a concurrent writer's temporary file.
      # Close the file before publishing it under the cache key.
      # @rbs directory: String
      # @rbs destination: String
      # @rbs prefix: String
      # @rbs payload: String
      # @rbs return: void
      def self.publish(directory, destination, prefix, payload)
        path = File.join(directory, ".wardite-#{SecureRandom.hex(16)}.tmp")
        file = File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
        begin
          file.binmode
          file.write(prefix)
          file.write(payload)
          file.close
          File.rename(path, destination)
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
