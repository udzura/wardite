# rbs_inline: enabled

module Wardite
  class Section
    attr_accessor :name #: String
  
    attr_accessor :code #: Integer

    attr_accessor :size #: Integer
  end

  class TypeSection < Section
    attr_accessor :defined_types #: Array[Array[Symbol]]

    attr_accessor :defined_results #: Array[Array[Symbol]]

    # @rbs return: void
    def initialize
      self.name = "Type"
      self.code = 0x1

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

  class TableSection < Section
    attr_accessor :table_types #: Array[Symbol]

    attr_accessor :table_limits #: Array[[Integer, Integer?]]

    # @rbs return: void
    def initialize
      self.name = "Table"
      self.code = 0x4

      @table_types = []
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

      attr_accessor :value #: wasmValue | Integer

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

    attr_accessor :table_indices #: Array[Integer]

    attr_accessor :table_offsets #: Array[Integer]

    # Rows are also shared with Store#elements. Keep the precise RBS type via
    # an alias rather than pinning Spinel's specialized nested-array layout.
    attr_accessor :element_indices #: Array[indexVector]

    # @rbs return: void
    def initialize
      self.name = "Elem"
      self.code = 0x9

      @table_indices = []
      @table_offsets = []
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
        index = block.type_index
        if index >= 0
          params = types&.defined_types&.[](index)
          results = types&.defined_results&.[](index)
          raise LoadError, "invalid block type index #{index}" unless params && results
          block.resolve(params, results)
        end
      end
    end

    # Keep the code section for on-demand MIR inspection after the host has
    # accessed the mutable decoded bodies or edited the store.
    attr_accessor :source_bytes #: String?
    attr_accessor :func_codes #:Array[CodeBody]

    # @rbs return: void
    def initialize
      self.name = "Code"
      self.code = 0xa

      @source_bytes = nil
      @func_codes = []
    end
  end

  class DataSection < Section
    class Segment
      attr_accessor :mode #: :active|:passive

      attr_accessor :mem_index #: Integer
      
      attr_accessor :offset #: Integer

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
      self.exports[desc.name] = desc
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

    attr_reader :global_imports #: Array[GlobalImport]

    attr_accessor :imports #: Array[ImportDesc]

    def initialize #: void
      self.name = "Import"
      self.code = 0x2

      @global_imports = []
      @imports = []
    end

    # @rbs &blk: (ImportDesc) -> void
    def add_desc(&blk)
      desc = ImportDesc.new
      blk.call(desc) if blk
      self.imports << desc
    end
  end

  module BinaryLoader
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
    def self.load_from_buffer(buf, import_object: {}, enable_wasi: true, engine: :efflorescence, disabled_optimizations: [], enabled_optimizations: [], mir_cse: false, mir_profile: false, mir_cache: nil, mir_cache_verify: :checksum, mir_cache_eager: false, emit_wmir: nil)
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
          section.global_imports.each do |desc|
            host = placeholders[desc.module_name.to_sym] ||= HashModule.new({})
            host.globals[desc.name.to_sym] = Global.numeric(desc.type, desc.mutable)
          end
          section.imports.each do |desc|
            placeholder = placeholders[desc.module_name.to_sym] ||= HashModule.new({})
            placeholder.hash[desc.name.to_sym] = -> (_store, _args) { raise LoadError, "host call during WMIR compilation" }
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
      if !asm
        raise LoadError, "buffer too short"
      end
      if asm != "\u0000asm"
        raise LoadError, "invalid preamble"
      end

      vstr = @buf.read(4)
      if !vstr
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
      globals = [] #: Array[ImportSection::GlobalImport]

      loop do
        code = @buf.getbyte
        break unless code

        section = case code
          when Wardite::SectionType
            type_section
          when Wardite::SectionImport
            imports = import_section
            globals = imports.global_imports
            imports
          when Wardite::SectionTag
            tag_section
          when Wardite::SectionFunction
            function_section
          when Wardite::SectionTable
            table_section
          when Wardite::SectionMemory
            memory_section
          when Wardite::SectionGlobal
            global_section(globals)
          when Wardite::SectionExport
            export_section
          when Wardite::SectionStart
            start_section
          when Wardite::SectionElement
            elem_section
          when Wardite::SectionCode
            source = @buf
            if artifact && source.is_a?(File)
              artifact.code_section(source, fetch_uleb128(source))
            else
              code_section(defer_code, keep_code)
            end
          when Wardite::SectionData
            data_section
          when Wardite::Const::SectionDataCount
            data_count_section
          when Wardite::SectionCustom
            unimplemented_skip_section(code)
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
      sbuf = StringIO.new(@buf.read(size) || raise("buffer too short"))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        fncode = assert_byte(sbuf)
        if fncode != 0x60
          raise LoadError, "not a function definition"
        end

        arglen = fetch_uleb128(sbuf)
        arg = [] #: Array[Symbol]
        arglen.times do
          case ty = assert_byte(sbuf)
          when 0x69
            arg << :exnref
          when 0x7f
            arg << :i32
          when 0x7e
            arg << :i64
          when 0x7d
            arg << :f32
          when 0x7c
            arg << :f64
          else
            raise LoadError, "unsupported value type: #{ty.inspect}"
          end
        end
        dest.defined_types << arg

        retlen = fetch_uleb128(sbuf)
        ret = [] #: Array[Symbol]
        retlen.times do
          case ty = assert_byte(sbuf)
          when 0x69
            ret << :exnref
          when 0x7f
            ret << :i32
          when 0x7e
            ret << :i64
          when 0x7d
            ret << :f32
          when 0x7c
            ret << :f64
          else
            raise LoadError, "unsupported value type: #{ty.inspect}"
          end
        end
        dest.defined_results << ret
      end

      dest
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
    def self.import_section
      dest = ImportSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(@buf.read(size) || raise("buffer too short"))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        mlen = fetch_uleb128(sbuf)
        module_name = assert_read(sbuf, mlen)
        nlen = fetch_uleb128(sbuf)
        name = assert_read(sbuf, nlen)
        kind = assert_byte(sbuf)

        if kind == 3
          type, mutable = read_global_type(sbuf)
          dest.global_imports << ImportSection::GlobalImport.new(module_name, name, type, mutable)
          next
        end
        raise LoadError, "tag imports are not supported" if kind == 4
        raise LoadError, "unsupported import kind #{kind} for #{module_name}.#{name}" unless kind == 0
        index = fetch_uleb128(sbuf)
        dest.add_desc do |desc|
          desc.module_name = module_name
          desc.name = name
          desc.kind = kind
          desc.sig_index = index
        end
      end

      dest
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
        flags = fetch_uleb128(sbuf)
        unless flags == 0 || flags == 1
          raise LoadError, "shared/memory64/custom-page memory limits are not supported"
        end
        min = fetch_uleb128(sbuf)
        max = flags == 1 ? fetch_uleb128(sbuf) : nil
        if min > 65536 || (max && (max > 65536 || max < min))
          raise LoadError, "invalid memory32 limits"
        end
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
      # StartSection won't use size
      func_index = fetch_uleb128(@buf)
      dest.func_index = func_index
      dest
    end

    # @rbs return: ElemSection
    def self.elem_section
      dest = ElemSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(@buf.read(size) || raise("buffer too short"))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        etype = fetch_uleb128(sbuf)
        unless etype == 0 || etype == 2
          raise LoadError, "unsupported element segment kind #{etype}"
        end
        dest.table_indices << (etype == 0 ? 0 : fetch_uleb128(sbuf))

        code = fetch_insn_while_end(sbuf)
        ops = code_body(StringIO.new(code))
        dest.table_offsets << decode_expr(ops)
        if etype == 2 && assert_byte(sbuf) != 0
          raise LoadError, "unsupported element type"
        end

        elms = [] #: Array[Integer]
        fetch_uleb128(sbuf).times { elms << fetch_uleb128(sbuf) }
        dest.element_indices << elms
      end
      raise LoadError, "trailing element section data" unless sbuf.eof?
      dest
    end

    # @rbs sbuf: StringIO
    # @rbs return: [Symbol, bool]
    def self.read_global_type(sbuf)
      type = Op.i2type(assert_byte(sbuf))
      mut = assert_byte(sbuf)
      raise LoadError, "unsupported global mutability flags" unless mut == 0 || mut == 1
      raise LoadError, "unsupported global type #{type}" unless Efflorescence::FunctionEntry.numeric_type?(type)
      [type, mut == 1]
    end

    # @rbs imports: Array[ImportSection::GlobalImport]
    # @rbs return: GlobalSection
    def self.global_section(imports)
      dest = GlobalSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(@buf.read(size) || raise("buffer too short"))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        gtype, mutable = read_global_type(sbuf)
        ops = decode_body(sbuf, expression: true).instructions
        ops.each do |op|
          case op[1]
          when :global_get, :i32_const, :i64_const, :f32_const, :f64_const, :end
            next
          else
            raise InvalidInitializer, "constant expression required"
          end
        end
        raise InvalidInitializer, "global initializer type mismatch" unless ops.size == 2
        op = ops.fetch(0)
        value = if op[1] == :global_get
          index = op[2].fetch(0)
          raise LoadError, "invalid global index operand" unless index.is_a?(Integer)
          imported = imports[index] || raise(InvalidInitializer, "unknown global #{index}")
          raise InvalidInitializer, "constant expression required" if imported.mutable
          raise InvalidInitializer, "global initializer type mismatch" unless imported.type == gtype
          index
        else
          raise InvalidInitializer, "global initializer type mismatch" unless op[1].to_s == "#{gtype}_const"
          decode_global_expr(ops)
        end

        global = GlobalSection::Global.new do |g|
          g.type = gtype
          g.mutable = mutable
          g.shared = false # always
          g.value = value
        end
        dest.globals << global
      end
      dest
    end
    
    # @rbs return: FunctionSection
    def self.function_section
      dest = FunctionSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(@buf.read(size) || raise("buffer too short"))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        index = fetch_uleb128(sbuf)
        dest.func_indices << index
      end
      dest
    end

    # @rbs return: TableSection
    def self.table_section
      dest = TableSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(@buf.read(size) || raise("buffer too short"))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        code = fetch_uleb128(sbuf)
        type = Op.i2type(code)
        dest.table_types << type

        flags = fetch_uleb128(sbuf)
        min = fetch_uleb128(sbuf)
        max = nil
        if flags != 0
          max = fetch_uleb128(sbuf)
        end
        dest.table_limits << [min, max]
      end
      dest
    end

    # @rbs defer_code: bool
    # @rbs keep_code: bool
    # @rbs return: CodeSection
    def self.code_section(defer_code = false, keep_code = false)
      size = fetch_uleb128(@buf)
      bytes = assert_read(@buf, size)
      section = decode_code_section(bytes, defer_code)
      section.source_bytes = bytes.freeze if keep_code
      section
    end

    # @rbs bytes: String
    # @rbs defer_code: bool
    # @rbs return: CodeSection
    def self.decode_code_section(bytes, defer_code = false)
      dest = CodeSection.new
      dest.size = bytes.bytesize
      sbuf = StringIO.new(bytes)

      len = fetch_uleb128(sbuf)
      len.times { dest.func_codes << read_function_body(sbuf, defer_code) }
      dest
    end

    # @rbs sbuf: StringIO
    # @rbs defer_code: bool
    # @rbs return: CodeSection::CodeBody
    def self.read_function_body(sbuf, defer_code = false)
      ilen = fetch_uleb128(sbuf)
      code = assert_read(sbuf, ilen)
      last_code = code.getbyte(-1)
      if ! last_code
        raise "[BUG] empty code fetched" # guard for steep check
      end
      if last_code != 0x0b
        $stderr.puts "warning: instruction not ended with inst end(0x0b): 0x0#{last_code}"
      end
      cbuf = StringIO.new(code)
      CodeSection::CodeBody.new do |body|
        locals_len = fetch_uleb128(cbuf)
        while locals_len > 0
          body.locals_count << fetch_uleb128(cbuf)
          body.locals_type << Op.i2type(assert_byte(cbuf))
          locals_len -= 1
        end
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
            value = fetch_uleb128(buf)
            if operand.empty? && opcode >= 0x28 && opcode <= 0x3e && value >= 64
              raise LoadError, "multi-memory memargs are not supported"
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

    # Decode s33, distinguishing the one-byte value/void forms from indices.
    # @rbs buf: File|StringIO
    # @rbs return: Block
    def self.read_blocktype(buf)
      first = buf.pos
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
    def self.data_section
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
          raise LoadError, "only memory 0 is supported" unless memory_index == 0
          raise LoadError, "data offset requires i32.const" unless assert_byte(sbuf) == 0x41
          offset = fetch_sleb128(sbuf, width: 32)
          raise LoadError, "constant expression requires end" unless assert_byte(sbuf) == 0x0b
          len = fetch_uleb128(sbuf)
          data = assert_read(sbuf, len).b
          segment = DataSection::Segment.new do |seg|
            seg.mode = :active
            seg.mem_index = memory_index
            seg.offset = offset & 0xffffffff
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
            seg.offset = 0 # unused
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

    # @rbs sbuf: StringIO
    # @rbs return: String
    def self.fetch_insn_while_end(sbuf)
      first = sbuf.pos
      opcode = assert_byte(sbuf)
      case opcode
      when 0x41 then fetch_sleb128(sbuf, width: 32)
      when 0x42 then fetch_sleb128(sbuf, width: 64)
      when 0x43 then assert_read(sbuf, 4)
      when 0x44 then assert_read(sbuf, 8)
      else raise LoadError, "unsupported constant expression"
      end
      raise LoadError, "constant expression requires end" unless assert_byte(sbuf) == 0x0b
      length = sbuf.pos - first
      sbuf.pos = first
      assert_read(sbuf, length)
    end

    # @rbs ops: Array[[Symbol, Symbol, Array[operandItem], Integer?, Integer?]]
    # @rbs return: Integer
    def self.decode_expr(ops)
      # sees first opcode
      op = ops.first
      if !op
        raise LoadError, "empty opcodes"
      end
      case op[1]
      when :i32_const
        arg = op[2][0]
        if !arg.is_a?(Integer)
          raise "Invalid definition of operand"
        end
        return arg
      else
        raise "Unimplemented offset op: #{op.inspect}"
      end
    end

    # @rbs ops: Array[[Symbol, Symbol, Array[operandItem], Integer?, Integer?]]
    # @rbs return: wasmValue
    def self.decode_global_expr(ops)
      # sees first opcode
      op = ops.first
      if !op
        raise LoadError, "empty opcodes"
      end
      case op[1]
      when :i32_const
        arg = op[2][0]
        if !arg.is_a?(Integer)
          raise "Invalid definition of operand"
        end
        return I32(arg)
      when :i64_const
        arg = op[2][0]
        if !arg.is_a?(Integer)
          raise "Invalid definition of operand"
        end
        return I64(arg)
      when :f32_const
        arg = op[2][0]
        raise "Invalid definition of operand" unless arg.is_a?(FloatImmediate)
        return F32.from_bits(arg.bits)
      when :f64_const
        arg = op[2][0]
        raise "Invalid definition of operand" unless arg.is_a?(FloatImmediate)
        return F64.from_bits(arg.bits)
      else
        raise "Unimplemented offset op: #{op.inspect}"
      end
    end

    # @rbs return: ExportSection
    def self.export_section
      dest = ExportSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(@buf.read(size) || raise("buffer too short"))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        nlen = fetch_uleb128(sbuf)
        name = assert_read(sbuf, nlen)
        kind = assert_byte(sbuf)

        raise LoadError, "tag exports are not supported" if kind == 4
        index = fetch_uleb128(sbuf)
        dest.add_desc do |desc|
          desc.name = name
          desc.kind = kind
          desc.index = index
        end
      end

      dest
    end

    # @rbs code: Integer
    # @rbs return: nil
    def self.unimplemented_skip_section(code)
      $stderr.puts "warning: unimplemented section: 0x0#{code}" if ENV['WARN_UNIMPLEMENTED_SECTION']
      size = fetch_uleb128(@buf)
      source = @buf
      if source.is_a?(File) && source.stat.file?
        raise LoadError, "truncated custom section" if size > source.stat.size - source.pos
        source.pos += size
      else
        assert_read(source, size)
      end
      nil
    end

    # @rbs sbuf: File|StringIO
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
