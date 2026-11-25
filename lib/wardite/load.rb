# rbs_inline: enabled

require "digest"

module Wardite
  class Section
    attr_accessor :name #: String
  
    attr_accessor :code #: Integer

    attr_accessor :size #: Integer
  end

  class TypeSection < Section
    attr_accessor :defined_types #: Array[Array[Symbol]]

    attr_reader :type_keys #: Array[String]

    attr_accessor :defined_results #: Array[Array[Symbol]]

    # @rbs return: void
    def initialize
      self.name = "Type"
      self.code = 0x1

      @type_keys = []
      @defined_types = []
      @defined_results = []
    end
  end

  class TagSection < Section
    attr_reader :type_indices #: Array[Integer]

    def initialize
      self.name = "Tag"
      self.code = Const::SectionTag
      @type_indices = []
    end
  end

  class FunctionSection < Section
    attr_accessor :func_indices #: Array[Integer]

    # @rbs return: void
    def initialize
      self.name = "Function"
      self.code = 0x3

      @func_indices = []
    end
  end

  class ConstantExpression
    include ValueHelper

    # @rbs instructions: Array[[Symbol, Symbol, Array[operandItem], Integer?, Integer?]]
    def initialize(instructions)
      @instructions = instructions
    end

    # @rbs instance: Instance
    # @rbs globals: Array[Global]
    # @rbs return: Integer
    def offset(instance, globals)
      value = evaluate(instance, globals)
      raise InvalidInitializer, "expected i32 offset" unless value.is_a?(I32)
      value.value
    end

    # @rbs instance: Instance
    # @rbs globals: Array[Global]
    # @rbs return: globalValue
    def evaluate(instance, globals)
      stack = [] #: Array[globalValue]
      @instructions.each do |op|
        arg = op[2][0]
        case op[1]
        when :i32_const, :i64_const
          raise InvalidInitializer, "invalid integer constant" unless arg.is_a?(Integer)
          stack << (op[1] == :i32_const ? I32(arg) : I64(arg))
        when :f32_const, :f64_const
          raise InvalidInitializer, "invalid float constant" unless arg.is_a?(FloatImmediate)
          stack << (op[1] == :f32_const ? F32.from_bits(arg.bits) : F64.from_bits(arg.bits))
        when :ref_null then stack << nil
        when :ref_func
          raise InvalidInitializer, "invalid function index" unless arg.is_a?(Integer)
          stack << FunctionReference.new(instance, arg)
        when :global_get
          raise InvalidInitializer, "invalid global index" unless arg.is_a?(Integer)
          stack << globals.fetch(arg).value
        when :i32_add, :i32_sub, :i32_mul
          right, left = stack.pop, stack.pop
          raise InvalidInitializer, "expected i32 operands" unless left.is_a?(I32) && right.is_a?(I32)
          a, b = left.value, right.value
          stack << I32(op[1] == :i32_add ? a + b : op[1] == :i32_sub ? a - b : a * b)
        when :i64_add, :i64_sub, :i64_mul
          right, left = stack.pop, stack.pop
          raise InvalidInitializer, "expected i64 operands" unless left.is_a?(I64) && right.is_a?(I64)
          a, b = left.value_s, right.value_s
          bits = case op[1]
          when :i64_add then Efflorescence::I64Arithmetic.add_i64(a, b)
          when :i64_sub then Efflorescence::I64Arithmetic.subtract_i64(a, b)
          else Efflorescence::I64Arithmetic.multiply_i64(a, b)
          end
          stack << I64(bits)
        end
      end
      stack.fetch(0)
    end
  end

  # Only declarations visible at this point in section order may be referenced.
  class InitializerContext
    attr_reader :globals #: Array[[Symbol, bool]]
    attr_reader :function_types #: Array[Integer]
    attr_reader :declared_functions #: Array[Integer]
    attr_accessor :types #: TypeSection

    def initialize #: void
      @globals = []
      @function_types = []
      @declared_functions = []
      @types = TypeSection.new
    end

    # @rbs sbuf: StringIO
    # @rbs expected: Symbol
    # @rbs return: ConstantExpression
    def read(sbuf, expected)
      ops = BinaryLoader.decode_body(sbuf, expression: true).instructions
      stack = [] #: Array[Symbol]
      ops.each do |op|
        case op[1]
        when :global_get
          index = op[2].fetch(0)
          raise LoadError, "invalid global index operand" unless index.is_a?(Integer)
          global = @globals[index]
          raise InvalidInitializer, "unknown global #{index}" unless global
          raise InvalidInitializer, "constant expression required" if global.fetch(1)
          stack << global.fetch(0)
        when :ref_func
          index = op[2].fetch(0)
          raise InvalidModule, "unknown function" unless index.is_a?(Integer)
          sig = @function_types[index]
          key = @types.type_keys[sig] if sig
          raise InvalidModule, "unknown function" unless key
          stack << "ref:#{key}".to_sym
          @declared_functions << index
        when :ref_null
          heap = op[2].fetch(0)
          raise InvalidInitializer, "expected heap type" unless heap.is_a?(Integer)
          stack << BinaryLoader.reference_type(0x63, heap, @types)
        when :i32_const, :i64_const, :f32_const, :f64_const
          stack << op[1].to_s.delete_suffix("_const").to_sym
        when :i32_add, :i32_sub, :i32_mul, :i64_add, :i64_sub, :i64_mul
          type = op[1].to_s.start_with?("i32") ? :i32 : :i64
          raise InvalidInitializer, "global initializer type mismatch" unless stack.pop == type && stack.pop == type
          stack << type
        when :end
          raise InvalidInitializer, "global initializer type mismatch" unless stack.size == 1 && Efflorescence::FunctionEntry.assignable?(stack.fetch(0), expected)
        else
          raise InvalidInitializer, "constant expression required"
        end
      end

      ConstantExpression.new(ops)
    end
  end

  class TableSection < Section
    attr_accessor :table_types #: Array[Symbol]

    attr_reader :initializers #: Array[ConstantExpression?]

    attr_accessor :table_limits #: Array[[Integer, Integer?]]

    # @rbs return: void
    def initialize
      self.name = "Table"
      self.code = 0x4

      @table_types = []
      @initializers = []
      @table_limits = []
    end
  end

  class MemorySection < Section
    attr_accessor :limits #: Array[[Integer, Integer?]]

    # @rbs return: void
    def initialize
      self.name = "Memory"
      self.code = 0x5

      @limits = []
    end
  end

  class GlobalSection < Section
    class Global
      attr_accessor :type #: Symbol
      
      attr_accessor :mutable #: bool

      # TODO: unused in wasm 1.0 spec?
      attr_accessor :shared #: bool

      attr_accessor :expression #: ConstantExpression

      # @rbs &blk: (Global) -> void
      # @rbs return: void
      def initialize(&blk)
        blk.call(self)
      end
    end

    attr_accessor :globals #: Array[Global]

    # @rbs return: void
    def initialize
      self.name = "Data"
      self.code = 0x6

      @globals = []
    end
  end

  class StartSection < Section
    attr_accessor :func_index #: Integer

    # @rbs return: void
    def initialize
      self.name = "Start"
      self.code = 0x8
      self.func_index = -1
    end
  end

  class ElemSection < Section
    # @rbs!
    #   type indexVector = Array[Integer]

    attr_reader :passive #: Array[bool]

    attr_accessor :table_indices #: Array[Integer]

    attr_reader :expressions #: Array[Array[ConstantExpression]]
    attr_accessor :table_offsets #: Array[ConstantExpression?]

    attr_reader :element_types #: Array[Symbol]
    attr_accessor :element_indices #: Array[indexVector]

    # @rbs return: void
    def initialize
      self.name = "Elem"
      self.code = 0x9

      @passive = []
      @table_indices = []
      @table_offsets = []
      @expressions = []
      @element_types = []
      @element_indices = []
    end
  end

  # The loader owns this result until a CodeBody exposes its mutable instructions.
  class DecodedBody
    attr_reader :instructions #: Array[[Symbol, Symbol, Array[operandItem], Integer?, Integer?]]
    attr_reader :blocks #: Array[Block]

    # @rbs instructions: Array[[Symbol, Symbol, Array[operandItem], Integer?, Integer?]]
    # @rbs blocks: Array[Block]
    def initialize(instructions, blocks)
      @instructions = instructions
      @blocks = blocks
    end
  end

  class CodeSection < Section
    class CodeBody
      attr_accessor :locals_count #: Array[Integer]

      attr_accessor :locals_type #: Array[Symbol]

      attr_writer :type_section #: TypeSection?

      # @rbs &blk: (CodeBody) -> void
      # @rbs return: void
      def initialize(&blk)
        @locals_count = []
        @locals_type = []
        @body = [] #: Array[[Symbol, Symbol, Array[operandItem], Integer?, Integer?]]
        @instruction_bytes = nil
        @instruction_map = nil #: IO::Buffer?
        @instruction_offset = @instruction_length = 0
        @decoded = nil #: DecodedBody?
        @type_section = nil
        blk.call(self)
      end

      # @rbs return: Array[[Symbol, Symbol, Array[operandItem], Integer?, Integer?]]
      def body
        check_features(@type_section) if @instruction_bytes || @instruction_map
        # The caller can mutate both the array and the Block objects in it.
        @decoded = nil
        @body
      end

      # @rbs instructions: Array[[Symbol, Symbol, Array[operandItem], Integer?, Integer?]]
      # @rbs return: void
      def body=(instructions)
        @body = instructions
        @instruction_map = nil
        @instruction_bytes = nil
        @decoded = nil
      end

      # @rbs bytes: String?
      # @rbs return: void
      def instruction_bytes=(bytes)
        @instruction_map = nil
        @instruction_bytes = bytes
        @decoded = nil
      end

      # @rbs map: IO::Buffer
      # @rbs offset: Integer
      # @rbs length: Integer
      # @rbs return: void
      def map_instructions(map, offset, length)
        @instruction_map = map
        @instruction_offset = offset
        @instruction_length = length
      end

      # @rbs buf: File|StringIO
      # @rbs return: void
      def decode_from(buf)
        install_decoded(BinaryLoader.decode_body(buf))
      end

      # @rbs types: TypeSection?
      # @rbs return: void
      def check_features(types)
        if (map = @instruction_map)
          @instruction_bytes = map.get_string(@instruction_offset, @instruction_length)
          @instruction_map = nil
        end
        if (bytes = @instruction_bytes)
          decoded = BinaryLoader.decode_body(StringIO.new(bytes))
          check_decoded(decoded, types)
          install_decoded(decoded)
        elsif (decoded = @decoded)
          check_decoded(decoded, types)
        else
          check_instructions(@body, types)
        end
      end

      private

      # @rbs decoded: DecodedBody
      # @rbs return: void
      def install_decoded(decoded)
        @body = decoded.instructions
        @instruction_bytes = nil
        @decoded = decoded
      end

      # @rbs decoded: DecodedBody
      # @rbs types: TypeSection?
      # @rbs return: void
      def check_decoded(decoded, types)
        decoded.blocks.each { |block| check_block(block, types) }
      end

      # @rbs instructions: Array[[Symbol, Symbol, Array[operandItem], Integer?, Integer?]]
      # @rbs types: TypeSection?
      # @rbs return: void
      def check_instructions(instructions, types)
        instructions.each do |instruction|
          instruction[2].each do |operand|
            check_block(operand, types) if operand.is_a?(Block)
          end
        end
      end

      # @rbs block: Block
      # @rbs types: TypeSection?
      # @rbs return: void
      def check_block(block, types)
        if block.reference_code != 0
          block.resolve([], [BinaryLoader.reference_type(block.reference_code, block.heap_type, types)])
          return
        end
        index = block.type_index
        if index >= 0
          params = types&.defined_types&.[](index)
          results = types&.defined_results&.[](index)
          raise LoadError, "invalid block type index #{index}" unless params && results
          raise InvalidModule, "expected function type" if types&.type_keys&.[](index)&.start_with?("s")
          block.resolve(params, results)
        end
      end
    end

    # Keep the code section for on-demand MIR inspection after the host has
    # accessed the mutable decoded bodies or edited the store.
    attr_accessor :source_bytes #: String?
    attr_reader :initializer_functions #: Array[Integer]
    attr_accessor :func_codes #:Array[CodeBody]

    # @rbs return: void
    def initialize
      self.name = "Code"
      self.code = 0xa

      @source_bytes = nil
      @initializer_functions = []
      @func_codes = []
    end
  end

  class DataSection < Section
    class Segment
      attr_accessor :mode #: :active|:passive

      attr_accessor :mem_index #: Integer
      
      attr_accessor :offset #: ConstantExpression?

      attr_accessor :data #: String

      # @rbs &blk: (Segment) -> void
      # @rbs return: void
      def initialize(&blk)
        blk.call(self)
      end
    end

    attr_accessor :segments #: Array[Segment]

    # @rbs return: void
    def initialize
      self.name = "Data"
      self.code = 0xb

      @segments = []
    end
  end

  class DataCountSection < Section
    attr_accessor :count #: Integer

    # @rbs count: Integer
    # @rbs return: void
    def initialize(count)
      self.name = "Data"
      self.code = 0xc

      @count = count
    end
  end

  class ExportSection < Section
    class ExportDesc
      attr_accessor :name #: String
      
      attr_accessor :kind #: Integer

      attr_accessor :index #: Integer
    end

    attr_accessor :exports #: Hash[String, ExportDesc]

    def initialize #: void
      self.name = "Export"
      self.code = 0x7

      @exports = {}
    end

    # @rbs &blk: (ExportDesc) -> void
    def add_desc(&blk)
      desc = ExportDesc.new
      blk.call(desc)
      raise InvalidModule, "duplicate export name" if @exports.key?(desc.name)
      @exports[desc.name] = desc
    end
  end

  class ImportSection < Section
    class ImportDesc
      attr_accessor :module_name #: String

      attr_accessor :name #: String
      
      attr_accessor :kind #: Integer

      attr_accessor :sig_index #: Integer
    end

    class GlobalImport
      attr_reader :module_name #: String
      attr_reader :name #: String
      attr_reader :type #: Symbol
      attr_reader :mutable #: bool

      # @rbs module_name: String
      # @rbs name: String
      # @rbs type: Symbol
      # @rbs mutable: bool
      def initialize(module_name, name, type, mutable)
        @module_name, @name, @type, @mutable = module_name, name, type, mutable
      end
    end

    attr_reader :table_imports #: Array[[String, String, Symbol, Integer, Integer?]]

    attr_reader :memory_imports #: Array[[String, String, Integer, Integer?]]

    attr_reader :tag_imports #: Array[ImportDesc]

    attr_reader :global_imports #: Array[GlobalImport]

    attr_accessor :imports #: Array[ImportDesc]

    def initialize #: void
      self.name = "Import"
      self.code = 0x2

      @table_imports = []
      @memory_imports = []
      @tag_imports = []
      @global_imports = []
      @imports = []
    end

    # @rbs &blk: (ImportDesc) -> void
    def add_desc(&blk)
      desc = ImportDesc.new
      blk.call(desc) if blk
      (desc.kind == 4 ? @tag_imports : @imports) << desc
    end
  end

  module BinaryLoader
    # Data count and exception tags precede sections with lower numeric IDs.
    SECTION_ORDER = [0, 1, 2, 3, 4, 5, 7, 8, 9, 10, 12, 13, 11, 6].freeze
    EMPTY_OPTIMIZATIONS = [] #: Array[Symbol]
    EMPTY_OPTIMIZATIONS.freeze

    extend Wardite::Leb128Helper
    extend Wardite::ValueHelper

    # @rbs self.@buf: File|StringIO

    # @rbs buf: File|StringIO
    # @rbs import_object: Hash[Symbol, wasmModuleSrc]
    # @rbs enable_wasi: boolish
    # @rbs engine: Symbol
    # @rbs mir_cse: bool
    # @rbs enabled_optimizations: Array[Symbol]
    # @rbs disabled_optimizations: Array[Symbol]
    # @rbs mir_profile: bool
    # @rbs emit_wmir: String?
    # @rbs mir_cache: String?
    # @rbs mir_cache_verify: Symbol
    # @rbs mir_cache_eager: bool
    # @rbs return: Instance
    def self.load_from_buffer(buf, import_object: {}, enable_wasi: true, engine: :efflorescence, disabled_optimizations: EMPTY_OPTIMIZATIONS, enabled_optimizations: EMPTY_OPTIMIZATIONS, mir_cse: false, mir_profile: false, mir_cache: nil, mir_cache_verify: :checksum, mir_cache_eager: false, emit_wmir: nil)
      start = Time.now.to_f #: Float
      unless mir_cache_verify == :checksum || mir_cache_verify == :sha256
        raise ArgumentError, "MIR cache verification must be checksum or sha256"
      end
      raise LoadError, "unknown engine: #{engine}" unless engine == :efflorescence
      @buf = buf
      cache = nil #: Efflorescence::MIRCache?
      artifact = nil #: Efflorescence::MIRArtifact?
      artifact_input = buf.is_a?(File) && File.extname(buf.path) == ".wmir"
      if artifact_input || emit_wmir
        raise ArgumentError, "WMIR cannot be combined with a cache directory or MIR profiling" if mir_cache || mir_profile
        raise ArgumentError, "expected Wasm input for --compile-wmir" if emit_wmir && artifact_input
      end
      if (mir_cache || artifact_input || emit_wmir) && !mir_profile
        require "wardite/efflorescence/mir_cache" unless RUBY_ENGINE == "spinel"
        bytes = "".b
        if artifact_input && buf.is_a?(File)
          artifact = Efflorescence::MIRArtifact.new(buf, mir_cache_verify)
          if disabled_optimizations.empty? && enabled_optimizations.empty? && !mir_cse
            enabled_optimizations = artifact.enabled
            disabled_optimizations = Efflorescence::Configuration::FEATURES - enabled_optimizations
          end
        else
          # Hash the same bytes that the decoder will see, even if the file changes.
          bytes = buf.read || "".b
          raise LoadError, "WMIR exceeds the Wasm size limit" if emit_wmir && bytes.bytesize > Efflorescence::MIRCache::MAX_BYTES
          @buf = StringIO.new(bytes)
        end
        configuration = Efflorescence::Configuration.new(disabled_optimizations, enabled: enabled_optimizations, cse: mir_cse)
        disabled_optimizations = configuration.disabled
        cache = Efflorescence::MIRCache.new(mir_cache || ".", bytes, configuration, verify: mir_cache_verify,
          eager: mir_cache_eager, artifact: artifact, output: emit_wmir)
      end

      version = preamble
      sections_ = sections(!cache.nil?, true, artifact)
      @buf = buf if cache

      wasi_env = nil
      if emit_wmir
        # Compilation uses import signatures only. Link actual hosts when loading the artifact.
        import_object = {} #: Hash[Symbol, wasmModuleSrc]
        sections_.each do |section|
          next unless section.is_a?(ImportSection)
          placeholders = {} #: Hash[Symbol, HashModule]
          section.table_imports.each do |mod, name, type, min, max|
            host = placeholders[mod.to_sym] ||= HashModule.new({})
            host.tables[name.to_sym] = Table.new(type, min, max)
          end
          section.memory_imports.each do |mod, name, min, max|
            host = placeholders[mod.to_sym] ||= HashModule.new({})
            host.memories[name.to_sym] = Memory.new(min, max)
          end
          section.global_imports.each do |desc|
            host = placeholders[desc.module_name.to_sym] ||= HashModule.new({})
            host.globals[desc.name.to_sym] = Global.numeric(desc.type, desc.mutable)
          end
          section.tag_imports.each do |desc|
            types = sections_.find { |item| item.is_a?(TypeSection) }
            raise LoadError, "missing tag type" unless types.is_a?(TypeSection)
            host = placeholders[desc.module_name.to_sym] ||= HashModule.new({})
            host.tags[desc.name.to_sym] = Efflorescence::Tag.new(types.defined_types.fetch(desc.sig_index), types.type_keys.fetch(desc.sig_index))
          end
          section.imports.each do |desc|
            placeholder = placeholders[desc.module_name.to_sym] ||= HashModule.new({})
            placeholder.register_function(desc.name.to_sym, -> (_store, _args) { raise LoadError, "host call during WMIR compilation" })
          end
          placeholders.each { |name, host| import_object[name] = host }
        end
      elsif enable_wasi && sections_.any? { |section| section.is_a?(ImportSection) &&
          section.imports.any? { |import| import.module_name == "wasi_snapshot_preview1" } }
        wasi_env = if RUBY_ENGINE == "spinel"
          Wardite::WasiSnapshotPreview1.new
        else
          require "wardite/efflorescence/wasi"
          Wardite::Efflorescence::WasiSnapshotPreview1.new
        end
        import_object[:wasi_snapshot_preview1] = wasi_env
      end

      return Instance.new(import_object, engine: engine, disabled_optimizations: disabled_optimizations,
        enabled_optimizations: enabled_optimizations, mir_cse: mir_cse,
        mir_profile: mir_profile, mir_cache: cache, eager_mir: mir_cache_eager) do |i|
        i.version = version
        i.sections = sections_
        i.wasi = wasi_env
      end
    ensure
      $stderr.puts "load_from_buffer: #{Time.now.to_f - start}" if ENV['WARDITE_TRACE']
    end

    # @rbs return: Integer
    def self.preamble
      asm = @buf.read 4
      if !asm || asm.bytesize < 4
        raise LoadError, "buffer too short"
      end
      if asm != "\u0000asm"
        raise LoadError, "invalid preamble"
      end

      vstr = @buf.read(4)
      if !vstr || vstr.bytesize < 4
        raise LoadError, "buffer too short"
      end
      version = vstr.unpack1("V")
      if !version.is_a?(Integer) || version != 1
        raise LoadError, "unsupported version: #{version}"
      end
      version
    end

    # @rbs defer_code: bool
    # @rbs keep_code: bool
    # @rbs return: Array[Section]
    # @rbs artifact: Efflorescence::MIRArtifact?
    def self.sections(defer_code = false, keep_code = false, artifact = nil)
      sections = [] #: Array[Section]
      context = InitializerContext.new
      previous = 0

      loop do
        code = @buf.getbyte
        break unless code

        if code != 0
          order = SECTION_ORDER[code] || raise(LoadError, "malformed section id")
          raise LoadError, "unexpected content after last section" if order <= previous
          previous = order
        end
        section = case code
          when Wardite::SectionType
            context.types = type_section
          when Wardite::SectionImport
            imports = import_section(context.types)
            imports.global_imports.each { |desc| context.globals << [desc.type, desc.mutable] }
            context.function_types.concat(imports.imports.map(&:sig_index))
            imports
          when Wardite::SectionTag
            tag_section
          when Wardite::SectionFunction
            functions = function_section
            context.function_types.concat(functions.func_indices)
            functions
          when Wardite::SectionTable
            table_section(context)
          when Wardite::SectionMemory
            memory_section
          when Wardite::SectionGlobal
            global_section(context)
          when Wardite::SectionExport
            export_section
          when Wardite::SectionStart
            start_section
          when Wardite::SectionElement
            elem_section(context)
          when Wardite::SectionCode
            source = @buf
            code_section_data = if artifact && source.is_a?(File)
              artifact.code_section(source, fetch_uleb128(source), context.types)
            else
              code_section(defer_code, keep_code, context.types)
            end
            code_section_data.initializer_functions.concat(context.declared_functions)
            code_section_data
          when Wardite::SectionData
            data_section(context)
          when Wardite::Const::SectionDataCount
            data_count_section
          when Wardite::SectionCustom
            custom_section
          else
            raise LoadError, "unknown code: #{code}(\"#{code.to_s 16}\")"
          end

        if section
          sections << section
        end
      end
      sections
    end

    # @rbs return: TypeSection
    def self.type_section
      dest = TypeSection.new

      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(assert_read(@buf, size))

      fetch_uleb128(sbuf).times do
        code = assert_byte(sbuf)
        grouped = code == 0x4e
        count = grouped ? fetch_uleb128(sbuf) : 1
        start = dest.type_keys.size
        raise LoadError, "truncated recursive type group" if count > size
        count.times { |i| dest.type_keys << "@#{i}" }
        shapes = [] #: Array[String]
        structs = [] #: Array[bool]
        count.times do
          form = grouped ? assert_byte(sbuf) : code
          params = [] #: Array[Symbol]
          results = [] #: Array[Symbol]
          if form == 0x60
            fetch_uleb128(sbuf).times { params << read_signature_type(sbuf, dest) }
            fetch_uleb128(sbuf).times { results << read_signature_type(sbuf, dest) }
            shapes << "func(#{params.join(',')})->(#{results.join(',')})"
          elsif form == 0x5f
            fields = [] #: Array[String]
            fetch_uleb128(sbuf).times do
              storage = read_signature_type(sbuf, dest)
              mutable = assert_byte(sbuf)
              raise LoadError, "invalid field mutability" unless mutable <= 1
              fields << "#{storage}/#{mutable}"
            end
            shapes << "struct(#{fields.join(',')})"
          else
            raise LoadError, "integer representation too long" if form >= 128
            raise LoadError, "unsupported composite type #{form}"
          end
          structs << (form == 0x5f)
          dest.defined_types << params
          dest.defined_results << results
        end
        # Intra-group references are relative. Earlier groups already have stable keys.
        shape = shapes.join("|")
        # Simple signatures can be used directly. Hash nested or large groups
        # to keep identity keys bounded and nested field boundaries unambiguous.
        if count > 1 || shape.bytesize > 64 || shape.include?(":")
          shape = Digest::SHA256.digest(shape).unpack1("H*").to_s
        end
        count.times do |i|
          dest.type_keys[start + i] = "#{structs.fetch(i) ? 's' : 'f'}#{i}:#{shape}"
        end
        count.times do |i|
          [dest.defined_types.fetch(start + i), dest.defined_results.fetch(start + i)].each do |signature|
            signature.map! do |type|
              name = type.to_s
              if name.start_with?("ref:@", "nullable:@")
                prefix, offset = name.split("@", 2)
                "#{prefix}#{dest.type_keys.fetch(start + offset.to_i)}".to_sym
              else
                type
              end
            end
          end
        end
      end
      raise LoadError, "trailing type section data" unless sbuf.eof?
      dest
    end

    # @rbs sbuf: StringIO|Efflorescence::MIRArtifact::CodeReader
    # @rbs return: Symbol
    # @rbs section: TypeSection
    def self.read_signature_type(sbuf, section)
      code = assert_byte(sbuf)
      if code == 0x63 || code == 0x64
        heap = fetch_sleb128(sbuf, width: 33)
        return reference_type(code, heap, section)
      end
      Op.i2type(code)
    end

    # @rbs code: Integer
    # @rbs heap: Integer
    # @rbs section: TypeSection?
    # @rbs return: Symbol
    def self.reference_type(code, heap, section)
      return code == 0x63 ? :funcref : :non_null_func if heap == -16
      return code == 0x63 ? :externref : :non_null_extern if heap == -17
      return code == 0x63 ? :exnref : :non_null_exn if heap == -23
      return code == 0x63 ? :anyref : Efflorescence::FunctionEntry.non_nullable(:anyref) if heap == -18
      return code == 0x63 ? :nullref : Efflorescence::FunctionEntry.non_nullable(:nullref) if heap == -15
      return code == 0x63 ? :nullexternref : Efflorescence::FunctionEntry.non_nullable(:nullexternref) if heap == -14
      return code == 0x63 ? :nullfuncref : Efflorescence::FunctionEntry.non_nullable(:nullfuncref) if heap == -13
      return code == 0x63 ? :nullexnref : Efflorescence::FunctionEntry.non_nullable(:nullexnref) if heap == -12
      key = section&.type_keys&.[](heap) if heap >= 0
      raise InvalidModule, "unknown type" if heap >= 0 && !key
      raise LoadError, "unsupported heap type #{heap}" unless key
      "#{code == 0x63 ? 'nullable' : 'ref'}:#{key}".to_sym
    end

    # @rbs return: TagSection
    def self.tag_section
      dest = TagSection.new
      dest.size = fetch_uleb128(@buf)
      sbuf = StringIO.new(assert_read(@buf, dest.size))
      fetch_uleb128(sbuf).times do
        raise LoadError, "unsupported tag attribute" unless assert_byte(sbuf) == 0
        dest.type_indices << fetch_uleb128(sbuf)
      end
      raise LoadError, "trailing tag section data" unless sbuf.eof?
      dest
    end

    # @rbs return: ImportSection
    # @rbs types: TypeSection
    def self.import_section(types)
      dest = ImportSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(assert_read(@buf, size))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        module_name = read_name(sbuf)
        name = read_name(sbuf)
        kind = assert_byte(sbuf)

        if kind == 1
          type, min, max = read_table_type(sbuf, types)
          dest.table_imports << [module_name, name, type, min, max]
          next
        end
        if kind == 2
          min, max = read_memory_limits(sbuf)
          dest.memory_imports << [module_name, name, min, max]
          next
        end
        if kind == 3
          type, mutable = read_global_type(sbuf, types)
          dest.global_imports << ImportSection::GlobalImport.new(module_name, name, type, mutable)
          next
        end
        if kind == 4
          raise LoadError, "unsupported tag attribute" unless assert_byte(sbuf) == 0
        end
        raise LoadError, "unsupported import kind #{kind} for #{module_name}.#{name}" unless kind == 0 || kind == 4
        index = fetch_uleb128(sbuf)
        dest.add_desc do |desc|
          desc.module_name = module_name
          desc.name = name
          desc.kind = kind
          desc.sig_index = index
        end
      end

      raise LoadError, "section size mismatch" unless sbuf.eof?
      dest
    end

    # @rbs sbuf: StringIO
    # @rbs return: [Integer, Integer?]
    def self.read_memory_limits(sbuf)
      flags = assert_byte(sbuf)
      unless flags == 0 || flags == 1
        raise LoadError, "shared/memory64/custom-page memory limits are not supported"
      end
      min = read_u64_for_i32(sbuf)
      max = flags == 1 ? read_u64_for_i32(sbuf) : nil
      if min > 65536 || (max && (max > 65536 || max < min))
        raise InvalidModule, "invalid memory32 limits"
      end
      [min, max]
    end

    # @rbs return: MemorySection
    def self.memory_section
      dest = MemorySection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(assert_read(@buf, size))

      len = fetch_uleb128(sbuf)
      if len > 1
        raise LoadError, "only one memory is supported: #{len}"
      end
      len.times do |i|
        min, max = read_memory_limits(sbuf)
        dest.limits << [min, max]
      end
      raise LoadError, "trailing memory section bytes" unless sbuf.eof?
      dest
    end

    # @rbs return: StartSection
    def self.start_section
      dest = StartSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(assert_read(@buf, size))
      func_index = fetch_uleb128(sbuf)
      raise LoadError, "section size mismatch" unless sbuf.eof?
      dest.func_index = func_index
      dest
    end

    # @rbs return: ElemSection
    # @rbs context: InitializerContext
    def self.elem_section(context)
      types = context.types
      dest = ElemSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(assert_read(@buf, size))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        etype = fetch_uleb128(sbuf)
        raise LoadError, "unsupported element segment kind #{etype}" unless etype.between?(0, 7)
        active = etype.even?
        table_index = case etype
        when 0, 4 then 0
        when 2, 6 then fetch_uleb128(sbuf)
        else -1
        end
        dest.table_indices << table_index
        dest.table_offsets << (active ? context.read(sbuf, :i32) : nil)
        if etype.between?(1, 3) && assert_byte(sbuf) != 0
          raise LoadError, "unsupported element type"
        end
        elms = [] #: Array[Integer]
        type = case etype
        when 0..3 then :non_null_func
        when 4 then :funcref
        else read_signature_type(sbuf, types)
        end
        raise LoadError, "malformed reference type" unless Efflorescence::FunctionEntry.reference?(type)
        dest.element_types << type
        dest.passive << (etype == 1 || etype == 5)
        expressions = [] #: Array[ConstantExpression]
        fetch_uleb128(sbuf).times do
          if etype >= 4
            expressions << context.read(sbuf, type)
          else
            elms << fetch_uleb128(sbuf)
          end
        end
        dest.expressions << expressions
        dest.element_indices << elms
      end
      raise LoadError, "trailing element section data" unless sbuf.eof?
      dest
    end

    # @rbs sbuf: StringIO
    # @rbs return: [Symbol, bool]
    # @rbs types: TypeSection
    def self.read_global_type(sbuf, types)
      type = read_signature_type(sbuf, types)
      mut = assert_byte(sbuf)
      raise LoadError, "unsupported global mutability flags" unless mut == 0 || mut == 1
      raise LoadError, "unsupported global type #{type}" unless Efflorescence::FunctionEntry.numeric_type?(type) || Efflorescence::FunctionEntry.reference?(type)
      [type, mut == 1]
    end

    # @rbs context: InitializerContext
    # @rbs return: GlobalSection
    def self.global_section(context)
      dest = GlobalSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(assert_read(@buf, size))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        gtype, mutable = read_global_type(sbuf, context.types)
        expression = context.read(sbuf, gtype)
        context.globals << [gtype, mutable]
        global = GlobalSection::Global.new do |g|
          g.type = gtype
          g.mutable = mutable
          g.shared = false # always
          g.expression = expression
        end
        dest.globals << global
      end
      raise LoadError, "section size mismatch" unless sbuf.eof?
      dest
    end
    
    # @rbs return: FunctionSection
    def self.function_section
      dest = FunctionSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(assert_read(@buf, size))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        index = fetch_uleb128(sbuf)
        dest.func_indices << index
      end
      raise LoadError, "section size mismatch" unless sbuf.eof?
      dest
    end

    # @rbs sbuf: StringIO
    # @rbs types: TypeSection
    # @rbs return: [Symbol, Integer, Integer?]
    def self.read_table_type(sbuf, types)
      type = read_signature_type(sbuf, types)
      raise InvalidModule, "expected table reference type" unless [:externref, :non_null_extern].include?(type) || Efflorescence::FunctionEntry.function_ref?(type)
      flags = assert_byte(sbuf)
      raise LoadError, "unsupported table limits" unless flags == 0 || flags == 1
      min = read_u64_for_i32(sbuf)
      max = flags == 1 ? read_u64_for_i32(sbuf) : nil
      raise InvalidModule, "invalid table limits" if min > 0xffffffff || (max && (max > 0xffffffff || max < min))
      [type, min, max]
    end

    # @rbs return: TableSection
    # @rbs context: InitializerContext
    def self.table_section(context)
      types = context.types
      dest = TableSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(assert_read(@buf, size))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        explicit = sbuf.string.getbyte(sbuf.pos) == 0x40
        if explicit
          assert_byte(sbuf)
          raise LoadError, "invalid table initializer prefix" unless assert_byte(sbuf).zero?
        end
        type, min, max = read_table_type(sbuf, types)
        raise InvalidModule, "non-defaultable table" if !explicit && (type.to_s.start_with?("ref:") || type == :non_null_func || type == :non_null_extern)
        dest.table_types << type
        dest.table_limits << [min, max]
        dest.initializers << (explicit ? context.read(sbuf, type) : nil)
      end
      dest
    end

    # @rbs defer_code: bool
    # @rbs keep_code: bool
    # @rbs return: CodeSection
    # @rbs types: TypeSection
    def self.code_section(defer_code = false, keep_code = false, types = TypeSection.new)
      size = fetch_uleb128(@buf)
      bytes = assert_read(@buf, size)
      section = decode_code_section(bytes, defer_code, types)
      section.source_bytes = bytes.freeze if keep_code
      section
    end

    # @rbs bytes: String
    # @rbs defer_code: bool
    # @rbs return: CodeSection
    # @rbs types: TypeSection
    def self.decode_code_section(bytes, defer_code = false, types = TypeSection.new)
      dest = CodeSection.new
      dest.size = bytes.bytesize
      sbuf = StringIO.new(bytes)

      len = fetch_uleb128(sbuf)
      len.times { dest.func_codes << read_function_body(sbuf, defer_code, types) }
      raise LoadError, "section size mismatch" unless sbuf.eof?
      dest
    end

    # @rbs sbuf: StringIO
    # @rbs defer_code: bool
    # @rbs return: CodeSection::CodeBody
    # @rbs types: TypeSection
    def self.read_function_body(sbuf, defer_code = false, types = TypeSection.new)
      ilen = fetch_uleb128(sbuf)
      code = assert_read(sbuf, ilen)
      raise LoadError, "END opcode expected" if code.empty?
      cbuf = StringIO.new(code)
      CodeSection::CodeBody.new do |body|
        locals_len = fetch_uleb128(cbuf)
        while locals_len > 0
          body.locals_count << fetch_uleb128(cbuf)
          body.locals_type << read_signature_type(cbuf, types)
          locals_len -= 1
        end
        raise LoadError, "too many locals" if body.locals_count.sum > 0xffffffff
        raise LoadError, "END opcode expected" if cbuf.eof?
        if defer_code
          body.instruction_bytes = (cbuf.read || "".b).freeze
        else
          body.decode_from(cbuf)
        end
      end
    end

    # @rbs buf: File|StringIO
    # @rbs return: Array[[Symbol, Symbol, Array[operandItem], Integer?, Integer?]]
    def self.code_body(buf)
      decode_body(buf).instructions
    end

    # @rbs buf: File|StringIO
    # @rbs return: DecodedBody
    # @rbs expression: bool
    def self.decode_body(buf, expression: false)
      dest = [] #: Array[[Symbol, Symbol, Array[operandItem], Integer?, Integer?]]
      blocks = [] #: Array[Block]
      # HINT: [symname, index of op, index of else, index of end]
      branching_stack = [] #: Array[[Symbol, Integer, Integer, Integer]]
      fixed_stack = [] #: Array[[Symbol, Integer, Integer, Integer]]
      ended = false
      while opcode = buf.getbyte
        spec = resolve_spec(opcode, buf)
        code = spec.code
        operand = [] #: Array[operandItem]
        spec.operand_types.each do |typ|
          case typ
          when :u8
            byte = buf.getbyte
            raise LoadError, "buffer too short" unless byte
            operand << byte
          when :u32
            value = if opcode.between?(0x28, 0x3e) && !operand.empty?
              read_u64_for_i32(buf)
            else
              fetch_uleb128(buf)
            end
            if operand.empty? && opcode.between?(0x28, 0x3e) && value >= 64
              raise LoadError, "malformed memop flags" if value >= 128
              memory = fetch_uleb128(buf)
              raise InvalidModule, "unknown memory #{memory}" unless memory.zero?
              value &= 63
            end
            operand << value
          when :u32_vec
            len = fetch_uleb128(buf)
            vec = [] #: Array[Integer]
            len.times do
              vec << fetch_uleb128(buf)
            end
            operand << OperandVector.new(vec)
          when :i32
            operand << fetch_sleb128(buf, width: 32)
          when :i64
            operand << fetch_sleb128(buf, width: 64)
          when :f32, :f64
            data = assert_read(buf, typ == :f32 ? 4 : 8)
            operand << FloatImmediate.new(typ, FloatBits.read(typ, data))
          when :heaptype
            operand << fetch_sleb128(buf, width: 33)
          when :select_types
            fetch_uleb128(buf).times do
              type = read_blocktype(buf)
              raise LoadError, "expected select value type" if type.type_index >= 0 || (type.reference_code == 0 && type.result_types.empty?)
              blocks << type
              operand << type
            end
          when :u8_block, :blocktype
            value = read_blocktype(buf)
            blocks << value
            operand << value
          when :catches
            clauses = [] #: Array[Integer]
            fetch_uleb128(buf).times do
              kind = assert_byte(buf)
              raise LoadError, "invalid catch kind #{kind}" unless kind <= 3
              tag = kind <= 1 ? fetch_uleb128(buf) : -1
              depth = fetch_uleb128(buf)
              clauses << kind << tag << depth
            end
            operand << OperandVector.new(clauses)
          else
            $stderr.puts "warning: unknown type #{typ.inspect}. defaulting to u32"
            operand << fetch_uleb128(buf)
          end         
        end

        # HINT: [namespace, code, operand, else_pos, end_pos]
        dest << [spec.namespace, code, operand, nil, nil]
        if code == :block || code == :loop || code == :if || code == :try_table
          branching_stack << [code, dest.size - 1, -1, -1]
        elsif code == :else
          if branching_stack.empty?
            raise "broken sequence: unmatched else"
          else
            last = branching_stack.pop || raise("[BUG] empty pop")
            if last[0] != :if
              raise "broken sequence: else without if"
            end
            branching_stack << [last[0], last[1], dest.size - 1, -1]
          end
        elsif code == :end
          if expression && branching_stack.empty?
            ended = true
            break
          end
          unless branching_stack.empty?
            last = branching_stack.pop || raise("[BUG] empty pop")
            fixed_stack << [last[0], last[1], last[2], dest.size - 1]
          end
        end
      end

      raise LoadError, "END opcode expected" if !expression && !dest.empty? && dest.last&.[](1) != :end
      raise LoadError, "unterminated constant expression" if expression && !ended
      raise LoadError, "unterminated structured control" unless branching_stack.empty?
      fixed_stack.each do |(sym, begin_idx, else_idx, end_idx)|
        if end_idx == -1
          raise "broken sequence: branching without end"
        end
        case sym
        when :block, :loop, :try_table
          dest[begin_idx][-1] = end_idx
        when :if
          dest[begin_idx][-2] = else_idx == -1 ? end_idx : else_idx
          dest[begin_idx][-1] = end_idx
        else
          raise "[BUG] unknown sym #{sym.inspect}"
        end
      end
      DecodedBody.new(dest, blocks)
    rescue => e
      require "pp"
      $stderr.puts "parsed:::"
      $stderr.puts "#{dest.pretty_inspect}"
      $stderr.puts "code = #{code}"
      raise e
    end

    # Table limits and memarg offsets use u64 even for 32-bit addresses.
    # Preserve overflow beyond i32 without overflowing a native register.
    # @rbs buf: File|StringIO
    # @rbs return: Integer
    def self.read_u64_for_i32(buf)
      value = 0
      10.times do |i|
        byte = assert_byte(buf)
        raise LoadError, "integer representation too long" if i == 9 && byte >= 128
        raise LoadError, "integer too large" if i == 9 && byte > 1
        part = byte & 127
        if i < 5
          value |= part << (7 * i)
        elsif part != 0
          value = 0x100000000
        end
        return value if byte < 128
      end
      raise LoadError, "unsigned LEB128 exceeds width"
    end

    # Decode s33, distinguishing the one-byte value/void forms from indices.
    # @rbs buf: File|StringIO
    # @rbs return: Block
    def self.read_blocktype(buf)
      first = buf.pos
      code = assert_byte(buf)
      if code == 0x63 || code == 0x64
        heap = fetch_sleb128(buf, width: 33)
        block = Block.void
        block.reference_code = code
        block.heap_type = heap
        return block
      end
      buf.pos = first
      value = fetch_sleb128(buf, max_level: 4)
      raise LoadError, "blocktype exceeds s33" unless value >= -4294967296 && value <= 4294967295
      if value < 0 && buf.pos - first != 1
        raise LoadError, "value/void blocktypes must use their single-byte encoding"
      end
      return Block.void if value == -64
      return Block.new(nil, type_index: value) if value >= 0
      raise LoadError, "invalid block value type" if value < -64
      code = value & 0x7f
      Op.i2type(code) # Reject unsupported/nonnullable reference declarations.
      Block.new([code])
    end

    # @rbs c: String
    # @rbs buf: File|StringIO
    # @rbs return: [Symbol, Symbol, Array[Symbol]]
    def self.resolve_code(c, buf)
      spec = resolve_spec(c.ord, buf)
      [spec.namespace, spec.code, spec.operand_types.dup]
    end

    # @rbs opcode: Integer
    # @rbs buf: File|StringIO
    # @rbs return: Op::DecodeSpec
    def self.resolve_spec(opcode, buf)
      return Op::REF_NULL_SPEC if opcode == 0xd0
      return Op::REF_AS_NON_NULL_SPEC if opcode == 0xd4
      return Op::BR_ON_NULL_SPEC if opcode == 0xd5
      return Op::BR_ON_NON_NULL_SPEC if opcode == 0xd6
      return Op::REF_IS_NULL_SPEC if opcode == 0xd1
      return Op::REF_FUNC_SPEC if opcode == 0xd2
      if opcode == 0xfc
        lower = fetch_uleb128(buf)
        # Preserve the unresolved opcode for the engine's unsupported-op check.
        Op::FC_SPECS[lower] || Op::DecodeSpec.new(:default, Op::FC_SYMS[lower], [])
      else
        Op::OPCODE_SPECS[opcode] || raise(LoadError, "unsupported code: #{opcode}")
      end
    end
    private_class_method :resolve_spec

    # @rbs return: DataSection
    # @rbs context: InitializerContext
    def self.data_section(context)
      dest = DataSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(assert_read(@buf, size))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        data_type = fetch_uleb128(sbuf)
        case data_type
        when 0x0, 0x2
          # Active explicit-memory segments still target memory 0 in M2.
          memory_index = data_type == 2 ? fetch_uleb128(sbuf) : 0
          offset = context.read(sbuf, :i32)
          len = fetch_uleb128(sbuf)
          data = assert_read(sbuf, len).b
          segment = DataSection::Segment.new do |seg|
            seg.mode = :active
            seg.mem_index = memory_index
            seg.offset = offset
            seg.data = data
          end
          dest.segments << segment
        when 0x1
          # passive
          dsize = fetch_uleb128(sbuf)
          data = assert_read(sbuf, dsize).b
          segment = DataSection::Segment.new do |seg|
            seg.mode = :passive
            seg.mem_index = 0 # unused
            seg.offset = nil
            seg.data = data
          end
          dest.segments << segment
        else
          raise LoadError, "unsupported data segment flags #{data_type}"
        end
      end
      raise LoadError, "trailing data section bytes" unless sbuf.eof?
      dest
    end

    # @rbs return: DataCountSection
    def self.data_count_section
      size = fetch_uleb128(@buf)
      sbuf = StringIO.new(assert_read(@buf, size))
      count = fetch_uleb128(sbuf)
      dest = DataCountSection.new(count)
      raise LoadError, "trailing data count bytes" unless sbuf.eof?
      dest.size = size
      dest
    end

    # @rbs return: ExportSection
    def self.export_section
      dest = ExportSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(assert_read(@buf, size))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        name = read_name(sbuf)
        kind = assert_byte(sbuf)

        index = fetch_uleb128(sbuf)
        dest.add_desc do |desc|
          desc.name = name
          desc.kind = kind
          desc.index = index
        end
      end

      raise LoadError, "section size mismatch" unless sbuf.eof?
      dest
    end

    # @rbs return: nil
    def self.custom_section
      $stderr.puts "warning: unimplemented section: 0x00" if ENV['WARN_UNIMPLEMENTED_SECTION']
      source = @buf
      size = fetch_uleb128(source)
      if source.is_a?(File) && source.stat.file?
        section_end = source.pos + size
        raise LoadError, "length out of bounds" if section_end > source.stat.size
        raise LoadError, "unexpected end" if size.zero?
        read_name(source, section_end)
        source.pos = section_end
      else
        read_name(StringIO.new(assert_read(source, size)))
      end
      nil
    end

    # @rbs source: File|StringIO
    # @rbs section_end: Integer?
    # @rbs return: String
    def self.read_name(source, section_end = nil)
      size = fetch_uleb128(source)
      if section_end && size > section_end - source.pos
        raise LoadError, "length out of bounds"
      end
      name = assert_read(source, size).force_encoding("UTF-8")
      raise LoadError, "malformed UTF-8 encoding" unless name.valid_encoding?
      name
    end

    # @rbs sbuf: File|StringIO|Efflorescence::MIRArtifact::CodeReader
    # @rbs return: Integer
    def self.assert_byte(sbuf)
      sbuf.getbyte || raise(LoadError, "too short section size")
    end

    # @rbs sbuf: File|StringIO
    # @rbs n: Integer
    # @rbs return: String
    def self.assert_read(sbuf, n)
      ret = sbuf.read n
      if !ret
        raise LoadError, "too short section size"
      end
      if ret.bytesize != n
        raise LoadError, "too short section size"
      end
      ret
    end
  end
end
