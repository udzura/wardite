# frozen_string_literal: true
# rbs_inline: enabled

require_relative "wardite/version"
require_relative "wardite/leb128"
require_relative "wardite/const"
require_relative "wardite/float_bits"
require_relative "wardite/instruction"
require_relative "wardite/value"
# Spinel needs the host mixin at load time to compile classes that include it.
if RUBY_ENGINE == "spinel"
  require_relative "wardite/wasi"
else
  require_relative "wardite/wasm_module"
end
require_relative "wardite/load"
require_relative "wardite/errors"

require "stringio"

module Wardite
  class Instance
    attr_accessor :version #: Integer

    attr_accessor :sections #: Array[Section]

    attr_accessor :runtime #: Efflorescence::VM

    attr_accessor :types #: Array[Type]

    attr_accessor :store #: Store

    attr_accessor :exports #: Exports

    attr_reader :tags #: Array[Wardite::Efflorescence::Tag]

    attr_reader :import_object #: Hash[Symbol, wasmModule]

    attr_accessor :wasi #: ::Wardite::WasiSnapshotPreview1?

    # @rbs import_object: Hash[Symbol, wasmModuleSrc]
    # @rbs engine: Symbol
    # @rbs mir_cse: bool
    # @rbs enabled_optimizations: Array[Symbol]
    # @rbs disabled_optimizations: Array[Symbol]
    # @rbs mir_profile: bool
    # @rbs eager_mir: bool
    # @rbs mir_cache: Efflorescence::MIRCache?
    # @rbs &blk: (Instance) -> void
    def initialize(import_object, engine: :efflorescence, disabled_optimizations: [], enabled_optimizations: [], mir_cse: false, mir_profile: false, mir_cache: nil, eager_mir: false, &blk)
      raise LoadError, "unknown engine: #{engine}" unless engine == :efflorescence
      @wasi = nil

      blk.call(self)
      import_object.each_pair do |k, v|
        if v.is_a?(Hash)
          import_object[k] = HashModule.new(v)
        end
      end

      @import_object = import_object #: Hash[Symbol, wasmModule]

      @tags = []
      check_module_features
      cached_functions = nil #: Array[Efflorescence::Function]?
      if mir_cache && !mir_profile
        cached_functions = mir_cache.read_functions(self)
      end
      types = type_section
      code_section&.func_codes&.each do |body|
        if cached_functions
          body.type_section = types
        else
          body.check_features(types)
        end
      end
      check_data_count
      @store = Store.new(self)
      @exports = Exports.new(self.export_section, store, @tags)

      @types = []
      type_section = self.type_section
      if type_section
        type_section.defined_types.each_with_index do |calltype, idx|
          rettype = type_section.defined_results[idx]
          @types << Type.new(calltype, rettype)
        end
      end

      # A cache hit can decode its own pending bodies on inspection. A cold
      # build replays the original bytes even if the host edits Store later.
      code = code_section
      source_code = code.source_bytes if code && !cached_functions
      code.source_bytes = nil if code
      @runtime = Efflorescence::VM.new(self, source_code: source_code, disabled_optimizations: disabled_optimizations,
        enabled_optimizations: enabled_optimizations, mir_cse: mir_cse, profile: mir_profile,
        mir_cache: mir_cache, cached_functions: cached_functions, cache_checked: true, eager_mir: eager_mir)
    end

    # Run before allocating Store/Exports or executing a start function.
    # @rbs return: void
    def check_module_features
      check_memory_initialization
      types = type_section
      import_section.imports.each do |import|
        params = types&.defined_types&.[](import.sig_index)
        results = types&.defined_results&.[](import.sig_index)
        raise LoadError, "invalid import type index #{import.sig_index}" unless params && results
        Efflorescence::FunctionEntry.check_signature(params, results, "#{import.module_name}.#{import.name}")
      end
      import_section.tag_imports.each do |desc|
        expected = declared_tag(desc.sig_index)
        host = @import_object.fetch(desc.module_name.to_sym, nil)
        tag = host.tags.fetch(desc.name.to_sym, nil) if host.is_a?(HashModule)
        raise LinkError, "unknown import" unless tag
        raise LinkError, "incompatible import" unless tag.type_key == expected.type_key
        @tags << tag
      end
      tag_section = @sections.find { |section| section.is_a?(TagSection) }
      if tag_section.is_a?(TagSection)
        tag_section.type_indices.each { |index| @tags << declared_tag(index) }
      end
      export_section.exports.each_value do |desc|
        raise InvalidModule, "unknown tag" if desc.kind == 4 && !@tags[desc.index]
      end
    end

    # @rbs index: Integer
    # @rbs return: Efflorescence::Tag
    def declared_tag(index)
      types = type_section
      params = types&.defined_types&.[](index)
      results = types&.defined_results&.[](index)
      raise LoadError, "invalid tag type index #{index}" unless types && params && results
      raise InvalidModule, "non-empty tag result type" unless results.empty?
      unless params.all? { |type| Efflorescence::FunctionEntry.numeric_type?(type) || Efflorescence::FunctionEntry.function_ref?(type) }
        raise LoadError, "unsupported tag payload type"
      end
      Efflorescence::Tag.new(params, types.type_keys.fetch(index))
    end

    # @rbs return: HashModule
    def as_import_module
      host = HashModule.new({})
      export_section.exports.each_pair do |name, desc|
        case desc.kind
        when 0
          host.register_function(name.to_sym, ExportedFunction.new(self, name))
        when 3 then host.globals[name.to_sym] = @store.globals.fetch(desc.index)
        when 4 then host.tags[name.to_sym] = @tags.fetch(desc.index)
        end
      end
      host
    end

    # @rbs &block: (Array[Symbol], Array[Symbol], CodeSection::CodeBody) -> void
    # @rbs return: void
    def each_defined_function(&block)
      functions = function_section
      codes = code_section
      if (functions&.func_indices&.size || 0) != (codes&.func_codes&.size || 0)
        raise LoadError, "function and code section lengths differ"
      end
      return unless functions && codes

      types = type_section
      functions.func_indices.each_with_index do |index, position|
        params = types&.defined_types&.[](index)
        results = types&.defined_results&.[](index)
        raise LoadError, "invalid function type index #{index}" unless params && results
        block.call(params, results, codes.func_codes.fetch(position))
      end
    end

    # Validate active segments before shared initialization can mutate memory.
    # @rbs return: void
    def check_memory_initialization
      segments = data_section&.segments
      return unless segments
      limits = memory_section&.limits
      segments.each do |segment|
        next unless segment.mode == :active
        unless limits && limits.size == 1 && segment.mem_index == 0
          raise LoadError, "active data segment requires memory 0"
        end
        size = limits.fetch(0).fetch(0) * 65536
        start = segment.offset
        unless start >= 0 && start <= size && segment.data.bytesize <= size - start
          raise LoadError, "active data segment out of bounds"
        end
      end
    end

    # @rbs return: void
    def check_data_count
      data_count = self.data_count_section&.count
      if data_count
        actual_count = self.data_section&.segments&.size || 0
        if (data_count != actual_count)
          raise LoadError, "invalid data segment count"
        end
      end
    end

    # @rbs return: ImportSection
    def import_section
      sec = @sections.find{|s| s.code == Const::SectionImport }
      if !sec.is_a?(ImportSection)
        # returns dummy empty section
        return ImportSection.new
      end
      sec
    end

    # @rbs return: TypeSection|nil
    def type_section
      sec = @sections.find{|s| s.code == Wardite::Const::SectionType }
      if !sec
        return nil
      end
      if !sec.is_a?(TypeSection)
        raise(GenericError, "instance doesn't have required section")
      end
      sec
    end

    # @rbs return: MemorySection|nil
    def memory_section
      sec = @sections.find{|s| s.code == Const::SectionMemory }
      if !sec
        return nil
      end
      if !sec.is_a?(MemorySection)
        raise(GenericError, "[BUG] found invalid memory section")
      end
      sec
    end

    # @rbs return: StartSection|nil
    def start_section
      sec = @sections.find{|s| s.code == Const::SectionStart }
      if !sec
        return nil
      end
      if !sec.is_a?(StartSection)
        raise(GenericError, "[BUG] found invalid start section")
      end
      sec
    end

    # @rbs return: GlobalSection|nil
    def global_section
      sec = @sections.find{|s| s.code == Const::SectionGlobal }
      if !sec
        return nil
      end
      if !sec.is_a?(GlobalSection)
        raise(GenericError, "instance doesn't have required section")
      end
      sec
    end

    # @rbs return: DataSection|nil
    def data_section
      sec = @sections.find{|s| s.code == Const::SectionData }
      if !sec
        return nil
      end
      if !sec.is_a?(DataSection)
        raise(GenericError, "[BUG] found invalid data section")
      end
      sec
    end

    # @rbs return: DataCountSection|nil
    def data_count_section
      sec = @sections.find{|s| s.code == Const::SectionDataCount }
      if !sec
        return nil
      end
      if !sec.is_a?(DataCountSection)
        raise(GenericError, "[BUG] found invalid data section")
      end
      sec
    end

    # @rbs return: FunctionSection|nil
    def function_section
      sec = @sections.find{|s| s.code == Const::SectionFunction }
      if !sec
        return nil
      end
      if !sec.is_a?(FunctionSection)
        raise(GenericError, "instance doesn't have required section")
      end
      sec
    end

    # @rbs return: TableSection?
    def table_section
      sec = @sections.find{|s| s.code == Const::SectionTable }
      if !sec
        return nil
      end
      if !sec.is_a?(TableSection)
        raise(GenericError, "instance doesn't have required section")
      end
      sec
    end

    # @rbs return: ElemSection?
    def elem_section
      sec = @sections.find{|s| s.code == Const::SectionElement }
      if !sec
        return nil
      end
      if !sec.is_a?(ElemSection)
        raise(GenericError, "instance doesn't have required section")
      end
      sec
    end

    # @rbs return: CodeSection|nil
    def code_section
      sec = @sections.find{|s| s.code == Const::SectionCode }
      if !sec
        return nil
      end
      if !sec.is_a?(CodeSection)
        raise(GenericError, "instance doesn't have required section")
      end
      sec
    end

    # @rbs return: ExportSection
    def export_section
      sec = @sections.find{|s| s.code == Const::SectionExport }
      if !sec
        return ExportSection.new
      end
      if !sec.is_a?(ExportSection)
        raise(GenericError, "instance doesn't have required section")
      end
      sec
    end
  end

  class Type
    attr_accessor :callsig #: Array[Symbol]

    attr_accessor :retsig #: Array[Symbol]

    # @rbs callsig: Array[Symbol]
    # @rbs retsig: Array[Symbol]
    # @rbs return: void
    def initialize(callsig, retsig)
      @callsig = callsig
      @retsig = retsig
    end
  end

  class Store
    attr_accessor :funcs #: Array[WasmFunction|ExternalFunction]

    attr_accessor :modules #: Hash[Symbol, wasmModule]

    attr_accessor :memories #: Array[Memory]

    attr_reader :data_segments #: Array[String]

    attr_accessor :globals #: Array[Global]

    attr_accessor :tables #: Array[Table]

    attr_accessor :elements #: Array[[Symbol, Integer, Array[Integer]]]

    # @rbs inst: Instance
    # @rbs return: void
    def initialize(inst)
      type_section = inst.type_section

      import_section = inst.import_section
      @funcs = []
      @modules = inst.import_object

      import_section.imports.each do |desc|
        callsig = type_section&.defined_types&.[](desc.sig_index)
        retsig = type_section&.defined_results&.[](desc.sig_index)
        raise LoadError, "invalid import type index #{desc.sig_index}" unless callsig && retsig

        module_name = desc.module_name.to_sym
        target_module = self.modules.fetch(module_name) { self.modules.default(module_name) }
        raise ::NameError, "module #{desc.module_name} not found" unless target_module

        name = desc.name.to_sym
        wasi = inst.wasi
        wasi.validate_import(name, callsig, retsig) if wasi && wasi.equal?(target_module)
        if target_module.is_a?(HashModule)
          exported = target_module.exported_function(name)
          if exported.is_a?(ExportedFunction)
            original = exported.instance.exports[exported.name]
            unless (original.is_a?(WasmFunction) || original.is_a?(ExternalFunction)) && original.callsig == callsig && original.retsig == retsig
              raise LinkError, "incompatible import"
            end
          end
        end
        self.funcs << ExternalFunction.new(target_module, name, callsig, retsig)
      end

      inst.each_defined_function do |callsig, retsig, body|
        wasm_function = WasmFunction.new(callsig, retsig, body)
        wasm_function.findex = self.funcs.size
        self.funcs << wasm_function
      end

      @memories = []
      memory_section = inst.memory_section
      if memory_section
        memory_section.limits.each do |(min, max)|
          self.memories << Memory.new(min, max)
        end

        data_section = inst.data_section
        if data_section
          data_section.segments.each do |segment|
            if segment.mode != :active
              next
            end
            memory = self.memories[segment.mem_index]
            if !memory
              raise GenericError, "invalid memory index: #{segment.mem_index}"
            end

            payload = segment.data
            unless memory.range?(segment.offset, payload.bytesize)
              raise GenericError, "data too large for memory"
            end
            memory.write_bytes(segment.offset, payload)
          end
        end
      end

      # Runtime segment instances differ from their syntax declarations: active
      # segments have already been consumed by initialization.
      @data_segments = []
      data_section = inst.data_section
      if data_section
        data_section.segments.each do |segment|
          @data_segments << (segment.mode == :passive ? segment.data.dup.b : "".b)
        end
      end

      @globals = []
      import_section.global_imports.each do |desc|
        module_name = desc.module_name.to_sym
        host = self.modules.fetch(module_name) { self.modules.default(module_name) }
        global = host.is_a?(HashModule) ? host.globals.fetch(desc.name.to_sym, nil) : nil
        raise LoadError, "unknown global import #{desc.module_name}.#{desc.name}" unless global
        unless global.type == desc.type && global.mutable == desc.mutable && !global.shared && global.valid_value?
          raise LoadError, "incompatible global import #{desc.module_name}.#{desc.name}"
        end
        @globals << global
      end
      global_section = inst.global_section
      if global_section
        global_section.globals.each do |g|
          @globals << Global.new do |g2|
            g2.type = g.type
            g2.mutable = g.mutable
            g2.shared = g.shared
            initializer = g.value
            g2.value = initializer.is_a?(Integer) ? @globals.fetch(initializer).value : initializer
          end
        end
      end

      @tables = []
      @elements = []
      table_section = inst.table_section
      if table_section
        table_section.table_types.each_with_index do |typ, idx|
          init, max = *table_section.table_limits[idx]
          if !init
            raise LoadError, "empty limits"
          end
          table = Table.new(typ, init, max)
          @tables << table
        end
      end

      elem_section = inst.elem_section
      if elem_section
        elem_section.declared_functions.each do |index|
          raise InvalidModule, "unknown function" unless @funcs[index]
        end
        elem_section.table_indices.each_with_index do |tidx, idx|
          table = @tables[tidx] || raise(LoadError, "invalid table index #{tidx}")
          offset = elem_section.table_offsets.fetch(idx)
          indices = elem_section.element_indices.fetch(idx)
          raise LoadError, "element segment requires a funcref table" unless table.type == :funcref
          if offset < 0 || offset > table.current || indices.size > table.current - offset
            raise LoadError, "active element segment out of bounds"
          end
          indices.each_with_index do |function_index, position|
            function = @funcs[function_index] if function_index >= 0
            raise LoadError, "invalid element function index #{function_index}" unless function
            table.set(offset + position, function)
          end
          @elements << [table.type, offset, indices]
        end
      end
    end

    # @rbs idx: Integer
    def [](idx)
      @funcs[idx]
    end
  end

  class Memory
    PAGE_SIZE = 65536 #: Integer
    MAX_PAGES = 65536 #: Integer

    # @rbs @data: String?
    # @rbs @buffer: IO::Buffer?
    # @rbs @storage: IO::Buffer?

    attr_accessor :current #: Integer
    attr_accessor :max #: Integer|nil

    # @rbs min: Integer
    # @rbs max: Integer|nil
    # @rbs return: void
    def initialize(min, max)
      if RUBY_ENGINE == "spinel"
        buffer = IO::Buffer.new(min * PAGE_SIZE)
        @storage = @buffer = buffer
      else
        @data = String.new("\0" * (min * PAGE_SIZE)).b
      end
      @current = min
      @max = max
    end

    # The CRuby host API retains the mutable backing String.
    # @rbs return: String
    def data
      @data || raise(NotImplementedError, "Spinel linear memory uses Memory#buffer")
    end

    # @rbs value: String
    # @rbs return: String
    def data=(value)
      raise NotImplementedError, "Spinel linear memory uses Memory#buffer" if RUBY_ENGINE == "spinel"
      @data = value
    end

    # The Spinel host API exposes only the current Wasm bytes. Reacquire it
    # after any guest call that can grow memory.
    # @rbs return: IO::Buffer
    def buffer
      @buffer || raise(NotImplementedError, "CRuby linear memory uses Memory#data")
    end

    # @rbs return: Integer
    def bytesize
      RUBY_ENGINE == "spinel" ? buffer.size : data.bytesize
    end

    # @rbs offset: Integer
    # @rbs length: Integer
    # @rbs return: bool
    def range?(offset, length)
      size = bytesize
      offset >= 0 && length >= 0 && offset <= size && length <= size - offset
    end

    # @rbs offset: Integer
    # @rbs length: Integer
    # @rbs return: String
    def read_bytes(offset, length)
      raise EvalError, "invalid memory range" unless range?(offset, length)
      return "".b if length == 0
      if RUBY_ENGINE == "spinel"
        buffer.get_string(offset, length)
      else
        data.byteslice(offset, length) || raise(EvalError, "invalid memory range")
      end
    end

    # @rbs offset: Integer
    # @rbs return: Integer
    def read_u32(offset)
      raise EvalError, "invalid memory range" unless range?(offset, 4)
      if RUBY_ENGINE == "spinel"
        Integer(buffer.get_value(:u32, offset))
      else
        Integer(data.unpack1("V", offset: offset))
      end
    end

    # @rbs offset: Integer
    # @rbs bytes: String
    # @rbs return: void
    def write_bytes(offset, bytes)
      length = bytes.bytesize
      raise EvalError, "invalid memory range" unless range?(offset, length)
      return if length == 0
      if RUBY_ENGINE == "spinel"
        buffer.set_string(bytes, offset)
      else
        data[offset, length] = bytes
      end
    end

    # @rbs delta: Integer
    # @rbs return: Integer
    def grow(delta)
      previous = current
      if RUBY_ENGINE == "spinel"
        declared = max
        limit = declared && declared < MAX_PAGES ? declared : MAX_PAGES
        return -1 if delta < 0 || previous > limit || delta > limit - previous
        return previous if delta == 0

        return -1 unless grow_buffer(previous + delta, limit)
      else
        declared = max
        return -1 if declared && previous + delta > declared
        self.data = data + String.new("\0" * (delta * PAGE_SIZE))
      end
      self.current = previous + delta
      previous
    end

    # Allocate the zeroed image for a validated snapshot. Every live byte
    # comes from the saved pages, so the old buffer can be discarded.
    # @rbs pages: Integer
    # @rbs return: bool
    def replace_snapshot_buffer(pages)
      limit = max
      return false if pages < current || pages > MAX_PAGES || (limit && pages > limit)
      return false if buffer.locked?
      replacement = allocate_storage(pages)
      return false unless replacement
      replace_storage(replacement, pages * PAGE_SIZE)
      self.current = pages
      true
    end

    def inspect
      preview = read_bytes(0, [bytesize, 64].min)
      "#<Wardite::Memory initial=#{bytesize.inspect} max=#{@max.inspect} preview=#{preview.inspect}...>"
    end

    private

    # @rbs pages: Integer
    # @rbs limit: Integer
    # @rbs return: bool
    def grow_buffer(pages, limit)
      old = buffer
      return false if old.locked?

      storage = @storage
      raise "missing linear memory storage" unless storage
      size = pages * PAGE_SIZE
      if size <= storage.size
        # Move ownership without copying. Spinel slices point to their
        # original root, so the transfer also invalidates outstanding views.
        replace_storage(storage.transfer, size)
        return true
      end

      spare = [pages / 8, 1].max
      capacity = [pages + spare, limit].min
      replacement = allocate_storage(capacity)
      replacement = allocate_storage(pages) if !replacement && capacity > pages
      return false unless replacement
      replacement.copy(old, 0, old.size) if old.size > 0
      replace_storage(replacement, size)
      true
    end

    # @rbs replacement: IO::Buffer
    # @rbs size: Integer
    # @rbs return: void
    def replace_storage(replacement, size)
      # Allocation zeroes the entire storage. The hidden suffix stays zero
      # because all guest and host accesses go through the size-bounded view.
      view = replacement.size == size ? replacement : replacement.slice(0, size)
      storage = @storage
      old = buffer
      old.free unless old.equal?(storage)
      storage&.free
      @storage = replacement
      @buffer = view
    end

    # @rbs pages: Integer
    # @rbs return: IO::Buffer?
    def allocate_storage(pages)
      IO::Buffer.new(pages * PAGE_SIZE)
    rescue NoMemoryError, Errno::ENOMEM, IO::Buffer::AllocationError
      nil
    end
  end

  class Table
    attr_accessor :type #: Symbol
    
    attr_accessor :current #: Integer

    attr_accessor :max #: Integer|nil
    
    attr_accessor :refs #: Array[WasmFunction|ExternalFunction|nil]

    # @rbs type: Symbol
    # @rbs init: Integer
    # @rbs max: Integer|nil
    # @rbs return: void
    def initialize(type, init, max)
      @type = type
      @current = init
      @max = max

      @refs = Array.new(3, nil)
    end

    # @rbs idx: Integer
    # @rbs elem: WasmFunction|ExternalFunction|nil
    # @rbs return: void
    def set(idx, elem)
      if idx < 0 || idx >= @current
        raise GenericError, "table index out of bounds"
      end
      @refs[idx] = elem
    end
  end

  class Global
    # @rbs type: Symbol
    # @rbs mutable: bool
    # @rbs return: Global
    def self.numeric(type, mutable)
      Global.new do |g|
        g.type = type
        g.mutable = mutable
        g.shared = false
        g.value = case type
        when :i32 then Wardite::I32(0)
        when :i64 then Wardite::I64(0)
        when :f32 then Wardite::F32.from_bits(0)
        when :f64 then Wardite::F64.from_bits(0)
        else raise LoadError, "unsupported global type #{type}"
        end
      end
    end

    attr_accessor :type #: Symbol
    
    attr_accessor :mutable #: bool

    # TODO: unused in wasm 1.0 spec?
    attr_accessor :shared #: bool

    attr_accessor :value #: wasmValue

    # @rbs &blk: (Global) -> void
    # @rbs return: void
    def initialize(&blk)
      blk.call(self)
    end

    # @rbs return: bool
    def valid_value?
      case type
      when :i32 then value.is_a?(I32)
      when :i64 then value.is_a?(I64)
      when :f32 then value.is_a?(F32)
      when :f64 then value.is_a?(F64)
      else false
      end
    end

    alias mutable? mutable
    alias shared? shared
  end

  class WasmData
    attr_accessor :memory_index #: Integer

    attr_accessor :offset #: Integer

    attr_accessor :init #: String

    # @rbs &blk: (WasmData) -> void
    # @rbs return: void
    def initialize(&blk)
      blk.call(self)
    end
  end

  class Block
    VOID = nil #: nil

    attr_accessor :reference_code #: Integer
    attr_accessor :heap_type #: Integer
    attr_accessor :block_types #: nil|Array[Integer]
    attr_reader :type_index #: Integer
    attr_reader :parameter_types #: Array[Symbol]
    attr_reader :result_types #: Array[Symbol]

    # @rbs return: Block
    def self.void
      new(VOID)
    end

    # @rbs block_types: nil|Array[Integer]
    # @rbs type_index: Integer
    # @rbs return: void
    def initialize(block_types=VOID, type_index: -1)
      @reference_code = @heap_type = 0
      @block_types = block_types
      @type_index = type_index
      @parameter_types = []
      @result_types = (block_types || []).map { |code| Op.i2type(code) }
    end

    # @rbs params: Array[Symbol]
    # @rbs results: Array[Symbol]
    # @rbs return: void
    def resolve(params, results)
      @parameter_types = params.dup
      @result_types = results.dup
    end

  end

  # @rbs!
  #   type exportHandle = WasmFunction | ExternalFunction | Table | Global | Memory | Efflorescence::Tag

  class Exports
    attr_accessor :mappings #: Hash[String, [Integer, exportHandle]]

    # @rbs export_section: ExportSection
    # @rbs store: Store
    # @rbs return: void
    # @rbs tags: Array[Efflorescence::Tag]
    def initialize(export_section, store, tags = [])
      @mappings = {}
      export_section.exports.each_pair do |name, desc|
        case desc.kind
        when 0x0
          @mappings[name] = [desc.kind, store.funcs[desc.index]]
        when 0x1
          @mappings[name] = [desc.kind, store.tables[desc.index]]
        when 0x2
          @mappings[name] = [desc.kind, store.memories[desc.index]]
        when 0x3
          @mappings[name] = [desc.kind, store.globals[desc.index]]
        when 0x4
          @mappings[name] = [desc.kind, tags.fetch(desc.index)]
        else
        end
      end
    end

    # @rbs name: String
    # @rbs return: exportHandle|nil
    def [](name)
      @mappings[name]&.[](1)
    end
  end

  # TODO: common interface btw. WasmFunction and ExternalFunction?
  #       may be _WasmCallable?
  class WasmFunction

    attr_accessor :callsig #: Array[Symbol]

    attr_accessor :retsig #: Array[Symbol]

    attr_accessor :code_body #: CodeSection::CodeBody

    attr_accessor :findex #: Integer

    # @rbs callsig: Array[Symbol]
    # @rbs retsig: Array[Symbol]
    # @rbs code_body: CodeSection::CodeBody
    # @rbs return: void
    def initialize(callsig, retsig, code_body)
      @callsig = callsig
      @retsig = retsig

      @code_body = code_body
      @findex = 0 # for debug
    end

    # @rbs return: Array[[Symbol, Symbol, Array[operandItem], Integer?, Integer?]]
    def body
      code_body.body
    end

    # @rbs return: Array[Symbol]
    def locals_type
      code_body.locals_type
    end

    # @rbs return: Array[Integer]
    def locals_count
      code_body.locals_count
    end

    # @rbs override_type: Type?
    # @rbs return: WasmFunction
    def clone(override_type: nil)
      if override_type
        # code_body is assumed to be frozen, so we can copy its ref
        WasmFunction.new(override_type.callsig, override_type.retsig, code_body)
      else
        WasmFunction.new(callsig, retsig, code_body)
      end
    end
  end

  # @rbs!
  #   type wasmFuncReturn = Object|nil

  class ExportedFunction
    attr_reader :instance #: Instance
    attr_reader :name #: String

    # @rbs instance: Instance
    # @rbs name: String
    def initialize(instance, name)
      @instance, @name = instance, name
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: wasmFuncReturn
    def call(store, args)
      @instance.runtime.call(@name, args)
    rescue UncaughtWasmException => error
      raise LinkedWasmException, error.exception_value
    end
    alias [] call
  end

  class FunctionReference
    attr_reader :instance #: Instance
    attr_reader :index #: Integer

    # @rbs instance: Instance
    # @rbs index: Integer
    def initialize(instance, index)
      @instance, @index = instance, index
    end
  end

  class ExternalFunction
    attr_accessor :target_module #: wasmModule

    attr_accessor :name #: Symbol

    attr_accessor :callsig #: Array[Symbol]

    attr_accessor :retsig #: Array[Symbol]

    #attr_accessor :callable #: _WasmCallable

    # @rbs callsig: Array[Symbol]
    # @rbs retsig: Array[Symbol]
    # @rbs target_module: wasmModule
    # @rbs name: Symbol
    # @rbs return: void
    def initialize(target_module, name, callsig, retsig)
      @target_module = target_module
      @name = name
      @callsig = callsig
      @retsig = retsig
    end

    # @rbs return: _WasmCallable
    def callable()
      target_module.callable(self.name)
    end

    # @rbs override_type: Type?
    # @rbs return: ExternalFunction
    def clone(override_type: nil)
      if override_type
        # callable is assumed to be frozen, so we can copy its ref
        ExternalFunction.new(target_module, name, override_type.callsig, override_type.retsig)
      else
        ExternalFunction.new(target_module, name, callsig, retsig)
      end
    end
  end

  class GenericError < StandardError; end
  class LoadError < StandardError; end
  class LinkError < LoadError; end
  class InvalidModule < LoadError; end
  class InvalidInitializer < LoadError; end
  class ArgumentError < StandardError; end
  class EvalError < StandardError; end
  class Unreachable < StandardError; end

  # @rbs path: String|nil
  # @rbs buffer: File|StringIO|nil
  # @rbs **options: Hash[Symbol, Object]
  # @rbs return: Instance
  def self.new(path: nil, buffer: nil, **options)
    if path
      return File.open(path, "rb") { |file| Wardite::BinaryLoader.load_from_buffer(file, **options) }
    end
    if buffer.nil?
      raise ::ArgumentError, "nil buffer passed"
    end
    Wardite::BinaryLoader.load_from_buffer(buffer, **options)
  end
end

require_relative "wardite/efflorescence"
