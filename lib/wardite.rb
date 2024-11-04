# frozen_string_literal: true
# rbs_inline: enabled

require_relative "wardite/version"
require_relative "wardite/leb128"
require_relative "wardite/const"
require_relative "wardite/instruction"
require_relative "wardite/value"

module Wardite
  module Evaluator
    extend Wardite::ValueHelper
  end
end
require_relative "wardite/alu_i32.generated"
require_relative "wardite/alu_i64.generated"
require_relative "wardite/alu_f32.generated"
require_relative "wardite/alu_f64.generated"
require_relative "wardite/convert.generated"

require_relative "wardite/wasi"

require "stringio"

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

  class MemorySection < Section
    attr_accessor :limits #: Array[[Integer, Integer|nil]]

    # @rbs return: void
    def initialize
      self.name = "Memory"
      self.code = 0x5

      @limits = []
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

    # @rbs buf: File|StringIO
    # @rbs import_object: Hash[Symbol, Hash[Symbol, Proc]]
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
            unimplemented_skip_section(code)
          when Wardite::SectionMemory
            memory_section
          when Wardite::SectionGlobal
            unimplemented_skip_section(code)
          when Wardite::SectionExport
            export_section
          when Wardite::SectionStart
            unimplemented_skip_section(code)
          when Wardite::SectionElement
            unimplemented_skip_section(code)
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
        namespace, code = Op.to_sym(c)
        operand_types = Op.operand_of(code)
        operand = [] #: Array[Integer|Float|Block]
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
          when :u8_if_block # :if specific
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

  class Instance
    attr_accessor :version #: Integer

    attr_accessor :sections #: Array[Section]

    attr_accessor :runtime #: Runtime

    attr_accessor :store #: Store

    attr_accessor :exports #: Exports

    attr_reader :import_object #: Hash[Symbol, Hash[Symbol, Proc]]

    # @rbs import_object: Hash[Symbol, Hash[Symbol, Proc]]
    # @rbs &blk: (Instance) -> void
    def initialize(import_object, &blk)
      blk.call(self)
      @import_object = import_object

      @store = Store.new(self)
      @exports = Exports.new(self.export_section, store)
      @runtime = Runtime.new(self)
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

  class Runtime
    include ValueHelper

    # TODO: add types of class that the stack accomodates
    attr_accessor :stack #: Array[I32|I64|F32|F64]

    attr_accessor :call_stack #: Array[Frame]

    attr_reader :instance #: Instance

    # @rbs inst: Instance
    def initialize(inst)
      @stack = []
      @call_stack = []
      @instance = inst
    end

    # @rbs name: String|Symbol
    # @rbs return: bool
    def callable?(name)
      !! @instance.exports[name.to_s]
    end

    # @rbs name: String|Symbol
    # @rbs args: Array[Object]
    # @rbs return: Object|nil
    def call(name, args)
      if !callable?(name)
        raise ::NoMethodError, "function #{name} not found"
      end
      kind, fn = @instance.exports[name.to_s]
      if kind != 0
        raise ::NoMethodError, "#{name} is not a function"
      end
      if fn.callsig.size != args.size
        raise ArgumentError, "unmatch arg size"
      end
      args.each_with_index do |arg, idx|
        case fn.callsig[idx]
        when :i32
          raise "type mismatch: i32(#{arg})" unless arg.is_a?(Integer)
          stack.push I32(arg)
        else
          raise "TODO: add me"
        end
      end

      case fn
      when WasmFunction
        invoke_internal(fn)
      when ExternalFunction
        invoke_external(fn)
      else
        raise GenericError, "registered pointer is not to a function"
      end
    end

    # @rbs wasm_function: WasmFunction
    # @rbs return: void
    def push_frame(wasm_function)
      local_start = stack.size - wasm_function.callsig.size
      locals = stack[local_start..]
      if !locals
        raise LoadError, "stack too short"
      end
      self.stack = drained_stack(local_start)

      wasm_function.locals_type.each_with_index do |typ, i|
        case typ
        when :i32, :u32
          locals.push I32(0)
        when :i64, :u64
          locals.push I64(0)
        else
          $stderr.puts "warning: unknown type #{typ.inspect}. default to I32"
          locals.push I32(0)
        end
      end

      arity = wasm_function.retsig.size
      frame = Frame.new(-1, stack.size, wasm_function.body, arity, locals)
      self.call_stack.push(frame)
    end

    # @rbs wasm_function: WasmFunction
    # @rbs return: Object|nil
    def invoke_internal(wasm_function)
      arity = wasm_function.retsig.size
      push_frame(wasm_function)
      execute!

      if arity > 0
        if arity > 1
          raise ::NotImplementedError, "return artiy >= 2 not yet supported ;;"
        end
        if self.stack.empty?
          raise "[BUG] stack empry"
        end
        v = self.stack.pop
        return v
      end

      return nil
    end

    # @rbs external_function: ExternalFunction
    # @rbs return: I32|I64|F32|F64|nil
    def invoke_external(external_function)
      local_start = stack.size - external_function.callsig.size
      args = stack[local_start..]
      if !args
        raise LoadError, "stack too short"
      end
      self.stack = drained_stack(local_start)

      proc = external_function.callable
      val = proc[self.instance.store, args]
      if !val
        return
      end

      case val
      when I32, I64, F32, F64
        return val
      when Integer
        case external_function.retsig[0]
        when :i32
          return I32(val)
        when :i64
          return I64(val)
        end
      when Float
        case external_function.retsig[0]
        when :f32
          return F32(val)
        when :f64
          return F64(val)
        end
      end

      raise "invalid type of value returned in proc. val: #{val.inspect}"
    end

    # @rbs return: void
    def execute!
      loop do
        cur_frame = self.call_stack.last #: Frame
        if !cur_frame
          break
        end
        cur_frame.pc += 1
        insn = cur_frame.body[cur_frame.pc]
        if !insn
          break
        end
        eval_insn(cur_frame, insn)
      end
    end

    # @rbs frame: Frame
    # @rbs insn: Op
    # @rbs return: void
    def eval_insn(frame, insn)
      case insn.namespace
      when :convert
        return Evaluator.convert_eval_insn(self, frame, insn)
      when :i32
        return Evaluator.i32_eval_insn(self, frame, insn)
      when :i64
        return Evaluator.i64_eval_insn(self, frame, insn)
      when :f32
        return Evaluator.f32_eval_insn(self, frame, insn)
      when :f64
        return Evaluator.f64_eval_insn(self, frame, insn)
      end

      # unmached namespace...
      case insn.code
      when :unreachable
        raise Unreachable, "unreachable op"
      when :nop
        return

      when :if
        block = insn.operand[0]
        raise EvalError, "if op without block" if !block.is_a?(Block)
        cond = stack.pop 
        raise EvalError, "cond not found" if !cond.is_a?(I32)
        next_pc = fetch_ops_while_end(frame.body, frame.pc)
        if cond.value.zero?
          frame.pc = next_pc
        end

        label = Label.new(:if, next_pc, stack.size, block.result_size)
        frame.labels.push(label)

      when :call
        idx = insn.operand[0]
        raise EvalError, "[BUG] local operand not found" if !idx.is_a?(Integer)
        fn = self.instance.store.funcs[idx]
        case fn
        when WasmFunction
          push_frame(fn)
        when ExternalFunction
          ret = invoke_external(fn)
          self.stack.push ret if ret
        else
          raise GenericError, "got a non-function pointer"
        end

      when :return
        old_frame = call_stack.pop
        if !old_frame
          raise EvalError, "maybe empty call stack"
        end

        stack_unwind(old_frame.sp, old_frame.arity)

      when :end
        if old_label = frame.labels.pop
          frame.pc = old_label.pc
          stack_unwind(old_label.sp, old_label.arity)
        else
          old_frame = call_stack.pop
          if !old_frame
            raise EvalError, "maybe empty call stack"
          end
          stack_unwind(old_frame.sp, old_frame.arity)
        end

      when :drop
        stack.pop

      when :select
        cond, right, left = stack.pop, stack.pop, stack.pop
        if !cond.is_a?(I32)
          raise EvalError, "invalid stack for select"
        end
        if !right || !left
          raise EvalError, "stack too short"
        end
        stack.push(cond.value != 0 ? left : right)

      when :local_get
        idx = insn.operand[0]
        if !idx.is_a?(Integer)
          raise EvalError, "[BUG] invalid type of operand"
        end
        local = frame.locals[idx]
        if !local
          raise EvalError, "local not found"
        end
        stack.push(local)

      when :local_set
        idx = insn.operand[0]
        if !idx.is_a?(Integer)
          raise EvalError, "[BUG] invalid type of operand"
        end
        value = stack.pop
        if !value
          raise EvalError, "value should be pushed"
        end
        frame.locals[idx] = value

      when :memory_size
        memory = instance.store.memories[0] || raise("[BUG] no memory")
        stack.push(I32(memory.current))

      when :memory_grow
        delta = stack.pop
        if !delta.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end
        memory = instance.store.memories[0] || raise("[BUG] no memory")
        stack.push(I32(memory.grow(delta.value)))

      else
        raise "TODO! unsupported #{insn.inspect}"
      end

    rescue => e
      require "pp"
      $stderr.puts "frame:::\n#{frame.pretty_inspect}"
      $stderr.puts "stack:::\n#{stack.pretty_inspect}"
      raise e
    end

    # @rbs ops: Array[Op]
    # @rbs pc_start: Integer
    # @rbs return: Integer
    def fetch_ops_while_end(ops, pc_start)
      cursor = pc_start
      depth = 0
      loop {
        cursor += 1
        inst = ops[cursor]
        case inst&.code
        when nil
          raise EvalError, "end op not found"
        when :i
          depth += 1
        when :end
          if depth == 0
            return cursor
          else
            depth -= 1
          end
        else
          # nop
        end
      }
      raise "[BUG] unreachable"
    end

    # unwind the stack and put return value if exists
    # @rbs sp: Integer
    # @rbs arity: Integer
    # @rbs return: void
    def stack_unwind(sp, arity)
      if arity > 0
        if arity > 1
          raise ::NotImplementedError, "return artiy >= 2 not yet supported ;;"
        end
        value = stack.pop
        if !value
          raise EvalError, "cannot obtain return value"
        end
        self.stack = drained_stack(sp)
        stack.push value
      else
        self.stack = drained_stack(sp)
      end
    end

    # @rbs finish: Integer
    # @rbs return: Array[I32|I64|F32|F64]
    def drained_stack(finish)
      drained = stack[0...finish]
      if ! drained
        $stderr.puts "warning: state of stack: #{stack.inspect}"
        raise EvalError, "stack too short"
      end
      return drained
    end

    # @rbs name: Symbol
    # @rbs args: Array[Object]
    # @rbs return: untyped
    def method_missing(name, *args)
      if callable? name
        call(name, args)
      else
        super
      end
    end

    # @rbs name: String|Symbol
    # @rbs return: bool
    def respond_to? name
      callable?(name) || super
    end
  end

  class Frame
    attr_accessor :pc #: Integer
    attr_accessor :sp #: Integer

    attr_accessor :body #: Array[Op]

    attr_accessor :arity #: Integer

    attr_accessor :labels #: Array[Label]

    attr_accessor :locals #: Array[I32|I64|F32|F64]

    # @rbs pc: Integer
    # @rbs sp: Integer
    # @rbs body: Array[Op]
    # @rbs arity: Integer
    # @rbs locals: Array[Object]
    # @rbs returb: void
    def initialize(pc, sp, body, arity, locals)
      @pc = pc
      @sp = sp
      @body = body
      @arity = arity
      @locals = locals
      @labels = []
    end
  end

  class Label
    attr_accessor :kind #: (:if|:loop|:block)

    attr_accessor :pc #: Integer
    attr_accessor :sp #: Integer

    attr_accessor :arity #: Integer

    # @rbs kind: (:if|:loop|:block)
    # @rbs pc: Integer
    # @rbs sp: Integer
    # @rbs arity: Integer
    # @rbs returb: void
    def initialize(kind, pc, sp, arity)
      @kind = kind
      @pc = pc
      @sp = sp
      @arity = arity
    end
  end

  class Store
    attr_accessor :funcs #: Array[WasmFunction|ExternalFunction]

    # FIXME: attr_accessor :modules
     
    attr_accessor :memories #: Array[Memory]

    # @rbs inst: Instance
    # @rbs return: void
    def initialize(inst)
      type_section = inst.type_section
      func_section = inst.function_section
      code_section = inst.code_section

      import_section = inst.import_section
      @funcs = []

      if type_section && func_section && code_section
        import_section.imports.each do |desc|
          callsig = type_section.defined_types[desc.sig_index]
          retsig = type_section.defined_results[desc.sig_index]
          imported_module = inst.import_object[desc.module_name.to_sym]
          if !imported_module
            raise ::NameError, "module #{desc.module_name} not found"
          end
          imported_proc = imported_module[desc.name.to_sym]
          if !imported_proc
            raise ::NameError, "function #{desc.module_name}.#{desc.name} not found"
          end
          
          ext_function = ExternalFunction.new(callsig, retsig, imported_proc)
          self.funcs << ext_function
        end

        func_section.func_indices.each_with_index do |sigindex, findex|
          callsig = type_section.defined_types[sigindex]
          retsig = type_section.defined_results[sigindex]
          codes = code_section.func_codes[findex]
          wasm_function = WasmFunction.new(callsig, retsig, codes)
          self.funcs << wasm_function
        end
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
            memory = self.memories[segment.flags]
            if !memory
              raise GenericError, "invalid memory index: #{segment.flags}"
            end

            data_start = segment.offset
            data_end = segment.offset + segment.data.size
            if data_end > memory.data.size
              raise GenericError, "data too large for memory"
            end

            memory.data[data_start...data_end] = segment.data
          end
        end
      end
    end

    # @rbs idx: Integer
    def [](idx)
      @funcs[idx]
    end
  end

  class Memory
    attr_accessor :data #: String

    attr_accessor :current #: Integer

    attr_accessor :max #: Integer|nil

    # @rbs min: Integer
    # @rbs max: Integer|nil
    # @rbs return: void
    def initialize(min, max)
      @data = String.new("\0" * (min * 64 * 1024))
      @current = min
      @max = max
    end

    # @rbs delta: Integer
    # @rbs return: Integer
    def grow(delta)
      prev = current
      newsize = current + delta
      if max && (newsize > max)
        return -1
      end
      
      @data += String.new("\0" * (delta * 64 * 1024))
      prev
    end

    def inspect
      "#<Wardite::Memory initial=#{@data.size.inspect} max=#{@max.inspect} @data=#{@data[0...64].inspect}...>"
    end
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

    attr_accessor :block_types #: nil|Array[Integer]

    # @rbs return: Block
    def self.void
      new(VOID)
    end

    # @rbs block_types: nil|Array[Integer]
    # @rbs return: void
    def initialize(block_types=VOID)
      @block_types = block_types
    end

    # @rbs return: bool
    def void?
      !!block_types
    end

    # @rbs return: Integer
    def result_size
      if block_types # !void?
        block_types.size
      else
        0
      end
    end
  end

  class Exports
    attr_accessor :mappings #: Hash[String, [Integer, WasmFunction|ExternalFunction]]

    # @rbs export_section: ExportSection
    # @rbs store: Store
    # @rbs return: void
    def initialize(export_section, store)
      @mappings = {}
      export_section.exports.each_pair do |name, desc|
        # TODO: introduce map by kind
        @mappings[name] = [desc.kind, store.funcs[desc.func_index]]
      end
    end

    # @rbs name: String
    # @rbs return: [Integer, WasmFunction|ExternalFunction]
    def [](name)
      @mappings[name]
    end
  end

  # TODO: common interface btw. WasmFunction and ExternalFunction?
  class WasmFunction
    attr_accessor :callsig #: Array[Symbol]

    attr_accessor :retsig #: Array[Symbol]

    attr_accessor :code_body #: CodeSection::CodeBody

    # @rbs callsig: Array[Symbol]
    # @rbs retsig: Array[Symbol]
    # @rbs code_body: CodeSection::CodeBody
    # @rbs return: void
    def initialize(callsig, retsig, code_body)
      @callsig = callsig
      @retsig = retsig

      @code_body = code_body
    end

    # @rbs return: Array[Op]
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
  end

  class ExternalFunction
    attr_accessor :callsig #: Array[Symbol]

    attr_accessor :retsig #: Array[Symbol]

    attr_accessor :callable #: Proc

    # @rbs callsig: Array[Symbol]
    # @rbs retsig: Array[Symbol]
    # @rbs callable: Proc
    # @rbs return: void
    def initialize(callsig, retsig, callable)
      @callsig = callsig
      @retsig = retsig
      @callable = callable
    end
  end

  class GenericError < StandardError; end
  class LoadError < StandardError; end
  class ArgumentError < StandardError; end
  class EvalError < StandardError; end
  class Unreachable < StandardError; end

  # @rbs path: String|nil
  # @rbs buffer: File|StringIO|nil
  # @rbs **options: Hash[Symbol, Object]
  # @rbs return: Instance
  def self.new(path: nil, buffer: nil, **options)
    if path
      buffer = File.open(path)
    end
    if !buffer
      raise ::ArgumentError, "nil buffer passed"
    end
    Wardite::BinaryLoader::load_from_buffer(buffer, **options);
  end
end
