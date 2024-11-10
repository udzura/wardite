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

      attr_accessor :value #: wasmValue

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
    attr_accessor :table_indices #: Array[Integer]

    attr_accessor :table_offsets #: Array[Integer]

    attr_accessor :element_indices #: Array[Array[Integer]]

    # @rbs return: void
    def initialize
      self.name = "Elem"
      self.code = 0x9

      @table_indices = []
      @table_offsets = []
      @element_indices = []
    end
  end

  class CodeSection < Section
    class CodeBody
      attr_accessor :locals_count #: Array[Integer]

      attr_accessor :locals_type #: Array[Symbol]

      attr_accessor :body #: Array[Op]

      # @rbs &blk: (CodeBody) -> void
      # @rbs return: void
      def initialize(&blk)
        blk.call(self)
      end
    end

    attr_accessor :func_codes #:Array[CodeBody]

    # @rbs return: void
    def initialize
      self.name = "Code"
      self.code = 0xa

      @func_codes = []
    end
  end

  class DataSection < Section
    class Segment
      attr_accessor :flags #: Integer
      
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

  class ExportSection < Section
    class ExportDesc
      attr_accessor :name #: String
      
      attr_accessor :kind #: Integer

      attr_accessor :func_index #: Integer
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

    attr_accessor :imports #: Array[ImportDesc]

    def initialize #: void
      self.name = "Import"
      self.code = 0x2

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
    # @rbs import_object: Hash[Symbol, Hash[Symbol, wasmCallable]]
    # @rbs enable_wasi: boolish
    # @rbs return: Instance
    def self.load_from_buffer(buf, import_object: {}, enable_wasi: true)
      @buf = buf

      version = preamble
      sections_ = sections

      if enable_wasi
        wasi_env = Wardite::WasiSnapshotPreview1.new       
        import_object[:wasi_snapshot_preview1] = wasi_env.to_module
      end

      return Instance.new(import_object) do |i|
        i.version = version
        i.sections = sections_
      end
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
      version = vstr.to_enum(:chars)
        .with_index
        .inject(0) {|dest, (c, i)| dest | (c.ord << i*8) }
      if version != 1
        raise LoadError, "unsupported version: #{version}"
      end
      version
    end

    # @rbs return: Array[Section]
    def self.sections
      sections = [] #: Array[Section]

      loop do
        byte = @buf.read(1)
        if !byte
          break
        end
        code = byte.ord

        section = case code
          when Wardite::SectionType
            type_section
          when Wardite::SectionImport
            import_section
          when Wardite::SectionFunction
            function_section
          when Wardite::SectionTable
            table_section
          when Wardite::SectionMemory
            memory_section
          when Wardite::SectionGlobal
            global_section
          when Wardite::SectionExport
            export_section
          when Wardite::SectionStart
            start_section
          when Wardite::SectionElement
            elem_section
          when Wardite::SectionCode
            code_section
          when Wardite::SectionData
            data_section
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
        fncode = assert_read(sbuf, 1)
        if fncode != "\x60"
          raise LoadError, "not a function definition"
        end

        arglen = fetch_uleb128(sbuf)
        arg = []
        arglen.times do
          case ty = assert_read(sbuf, 1)&.ord
          when 0x7f
            arg << :i32
          when 0x7e
            arg << :i64
          when 0x7d
            arg << :f32
          when 0x7c
            arg << :f64
          else
            raise NotImplementedError, "unsupported for now: #{ty.inspect}"
          end
        end
        dest.defined_types << arg

        retlen = fetch_uleb128(sbuf)
        ret = []
        retlen.times do
          case ty = assert_read(sbuf, 1)&.ord
          when 0x7f
            ret << :i32
          when 0x7e
            ret << :i64
          when 0x7d
            ret << :f32
          when 0x7c
            ret << :f64
          else
            raise NotImplementedError, "unsupported for now: #{ty.inspect}"
          end
        end
        dest.defined_results << ret
      end

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
        kind_ = assert_read(sbuf, 1)
        kind = kind_[0]&.ord
        if !kind
          raise "[BUG] empty unpacked string" # guard rbs
        end

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
      sbuf = StringIO.new(@buf.read(size) || raise("buffer too short"))

      len = fetch_uleb128(sbuf)
      if len != 1
        raise LoadError, "memory section has invalid size: #{len}"
      end
      len.times do |i|
        flags = fetch_uleb128(sbuf)
        min = fetch_uleb128(sbuf)

        max = nil
        if flags != 0
          max = fetch_uleb128(sbuf)
        end
        dest.limits << [min, max]
      end
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
        case etype
        when 0x0 # expr, vec(funcidx)
          dest.table_indices << 0 # default and fixed to table[0]

          code = fetch_insn_while_end(sbuf)
          ops = code_body(StringIO.new(code))
          offset = decode_expr(ops)
          dest.table_offsets << offset

          elms = []
          elen = fetch_uleb128(sbuf)
          elen.times do |i|
            index = fetch_uleb128(sbuf)
            elms << index
          end
          dest.element_indices << elms
        else
          raise NotImplementedError, "element section type #{etype} is a TODO!"
        end
      end
      dest
    end

    # @rbs return: GlobalSection
    def self.global_section
      dest = GlobalSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(@buf.read(size) || raise("buffer too short"))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        typeb = fetch_uleb128(sbuf)
        gtype = Op.i2type(typeb)
        mut = sbuf.read 1
        if !mut
          raise LoadError, "global section too short"
        end
        
        code = fetch_insn_while_end(sbuf)
        ops = code_body(StringIO.new(code))
        value = decode_global_expr(ops)

        global = GlobalSection::Global.new do |g|
          g.type = gtype
          g.mutable = (mut.ord == 0x01)
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

    # @rbs return: CodeSection
    def self.code_section
      dest = CodeSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(@buf.read(size) || raise("buffer too short"))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        ilen = fetch_uleb128(sbuf)
        code = assert_read(sbuf, ilen)
        last_code = code[-1]
        if ! last_code
          raise "[BUG] empty code fetched" # guard for steep check
        end
        if last_code.ord != 0x0b
          $stderr.puts "warning: instruction not ended with inst end(0x0b): 0x0#{last_code.ord}" 
        end
        cbuf = StringIO.new(code)
        locals_count = []
        locals_type = []
        locals_len = fetch_uleb128(cbuf)
        locals_len.times do
          type_count = fetch_uleb128(cbuf)
          locals_count << type_count
          value_type = assert_read(cbuf, 1)&.ord
          locals_type << Op.i2type(value_type || -1)
        end
        body = code_body(cbuf)
        dest.func_codes << CodeSection::CodeBody.new do |b|
          b.locals_count = locals_count
          b.locals_type = locals_type
          b.body = body
        end
      end
      dest
    end

    # @rbs buf: StringIO
    # @rbs return: Array[::Wardite::Op]
    def self.code_body(buf)
      dest = []
      while c = buf.read(1)
        namespace, code = resolve_code(c, buf)
        operand_types = Op.operand_of(code)
        operand = [] #: Array[operandItem]
        operand_types.each do |typ|
          case typ
          when :u8
            ope = buf.read 1
            if ! ope
              raise LoadError, "buffer too short"
            end
            operand << ope.ord
          when :u32
            operand << fetch_uleb128(buf)
          when :u32_vec
            len = fetch_uleb128(buf)
            vec = [] #: Array[Integer]
            len.times do
              vec << fetch_uleb128(buf)
            end
            operand << vec
          when :i32
            operand << fetch_sleb128(buf)
          when :i64
            operand << fetch_sleb128(buf)
          when :f32
            data = buf.read 4
            if !data || data.size != 4
              raise LoadError, "buffer too short"
            end
            v = data.unpack("e")[0]
            raise "String#unpack is broken" if !v.is_a?(Float)
            operand << v
          when :f64
            data = buf.read 8
            if !data || data.size != 8
              raise LoadError, "buffer too short"
            end
            v = data.unpack("E")[0]
            raise "String#unpack is broken" if !v.is_a?(Float)
            operand << v
          when :u8_block
            block_ope = buf.read 1
            if ! block_ope
              raise LoadError, "buffer too short for if"
            end
            if block_ope.ord == 0x40
              operand << Block.void
            else
              operand << Block.new([block_ope.ord])
            end
          else
            $stderr.puts "warning: unknown type #{typ.inspect}. defaulting to u32"
            operand << fetch_uleb128(buf)
          end         
        end

        dest << Op.new(namespace, code, operand)
      end

      dest
    end

    # @rbs c: String
    # @rbs buf: StringIO
    # @rbs return: [Symbol, Symbol]
    def self.resolve_code(c, buf)
      namespace, code = Op.to_sym(c)
      if namespace == :fc
        lower = fetch_uleb128(buf)
        return Op.resolve_fc_sym(lower) #: [Symbol, Symbol]
      end
      return [namespace, code] #: [Symbol, Symbol]
    end

    # @rbs return: DataSection
    def self.data_section
      dest = DataSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(@buf.read(size) || raise("buffer too short"))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        mem_index = fetch_uleb128(sbuf)
        code = fetch_insn_while_end(sbuf)
        ops = code_body(StringIO.new(code))
        offset = decode_expr(ops)

        len = fetch_uleb128(sbuf)
        data = sbuf.read len
        if !data
          raise LoadError, "buffer too short"
        end

        segment = DataSection::Segment.new do |seg|
          seg.flags = mem_index
          seg.offset = offset
          seg.data = data
        end
        dest.segments << segment
      end
      dest
    end

    # @rbs sbuf: StringIO
    # @rbs return: String
    def self.fetch_insn_while_end(sbuf)
      code = String.new("")
      loop {
        c = sbuf.read 1
        if !c
          break
        end
        code << c
        if c == "\u000b" # :end
          break
        end
      }
      code
    end

    # @rbs ops: Array[Op]
    # @rbs return: Integer
    def self.decode_expr(ops)
      # sees first opcode
      op = ops.first
      if !op
        raise LoadError, "empty opcodes"
      end
      case op.code
      when :i32_const
        arg = op.operand[0]
        if !arg.is_a?(Integer)
          raise "Invalid definition of operand"
        end
        return arg
      else
        raise "Unimplemented offset op: #{op.code.inspect}"
      end
    end

    # @rbs ops: Array[Op]
    # @rbs return: wasmValue
    def self.decode_global_expr(ops)
      # sees first opcode
      op = ops.first
      if !op
        raise LoadError, "empty opcodes"
      end
      case op.code
      when :i32_const
        arg = op.operand[0]
        if !arg.is_a?(Integer)
          raise "Invalid definition of operand"
        end
        return I32(arg)
      when :i64_const
        arg = op.operand[0]
        if !arg.is_a?(Integer)
          raise "Invalid definition of operand"
        end
        return I64(arg)
      when :f32_const
        arg = op.operand[0]
        if !arg.is_a?(Float)
          raise "Invalid definition of operand"
        end
        return F32(arg)
      when :f64_const
        arg = op.operand[0]
        if !arg.is_a?(Float)
          raise "Invalid definition of operand"
        end
        return F64(arg)
      else
        raise "Unimplemented offset op: #{op.code.inspect}"
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
        kind_ = assert_read(sbuf, 1)
        kind = kind_[0]&.ord
        if !kind
          raise "[BUG] empty unpacked string" # guard rbs
        end

        index = fetch_uleb128(sbuf)
        dest.add_desc do |desc|
          desc.name = name
          desc.kind = kind
          desc.func_index = index
        end
      end

      dest
    end

    # @rbs code: Integer
    # @rbs return: nil
    def self.unimplemented_skip_section(code)
      $stderr.puts "warning: unimplemented section: 0x0#{code}"
      size = @buf.read(1)&.ord
      @buf.read(size)
      nil
    end

    # @rbs sbuf: StringIO
    # @rbs n: Integer
    # @rbs return: String
    def self.assert_read(sbuf, n)
      ret = sbuf.read n
      if !ret
        raise LoadError, "too short section size"
      end
      if ret.size != n
        raise LoadError, "too short section size"
      end
      ret
    end
  end
end