# frozen_string_literal: true
# rbs_inline: enabled

require_relative "waru/version"
require_relative "waru/leb128"
require_relative "waru/const"
require_relative "waru/instruction"

require "stringio"

module Waru
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
    extend Waru::Leb128Helpers

    # @rbs buf: File|StringIO
    # @rbs import_object: Hash[Symbol, Hash[Symbol, Proc]]
    # @rbs return: Instance
    def self.load_from_buffer(buf, import_object: {})
      @buf = buf

      version = preamble
      sections_ = sections

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
          when Waru::SectionType
            type_section
          when Waru::SectionImport
            import_section
          when Waru::SectionFunction
            function_section
          when Waru::SectionTable
            unimplemented_skip_section(code)
          when Waru::SectionMemory
            memory_section
          when Waru::SectionGlobal
            unimplemented_skip_section(code)
          when Waru::SectionExport
            export_section
          when Waru::SectionStart
            unimplemented_skip_section(code)
          when Waru::SectionElement
            unimplemented_skip_section(code)
          when Waru::SectionCode
            code_section
          when Waru::SectionData
            data_section
          when Waru::SectionCustom
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
    # @rbs return: Array[::Waru::Op]
    def self.code_body(buf)
      dest = []
      while c = buf.read(1)
        code = Op.to_sym(c)
        operand_types = Op.operand_of(code)
        operand = []
        operand_types.each do |typ|
          case typ
          when :u32
            operand << fetch_uleb128(buf)
          when :i32
            operand << fetch_sleb128(buf)
          else
            $stderr.puts "warning: unknown type #{typ.inspect}. defaulting to u32"
            operand << fetch_uleb128(buf)
          end         
        end

        dest << Op.new(code, operand)
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
      sec = @sections.find{|s| s.code == Waru::Const::SectionType }
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
    attr_accessor :stack #: Array[Object]

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
      args.each do |arg|
        stack.push arg
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

    # @rbs idx: Integer
    # @rbs args: Array[Object]
    # @rbs return: Object|nil
    def call_index(idx, args)
      fn = self.instance.store[idx]
      if !fn
        # TODO: own error NoFunctionError
        raise ::NoMethodError, "func #{idx} not found"
      end
      if fn.callsig.size != args.size
        raise ArgumentError, "unmatch arg size"
      end
      args.each do |arg|
        stack.push arg
      end

      case fn
      when WasmFunction
        invoke_internal(fn)
      when ExternalFunction
        # invoke_external(fn)
        nil
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
          # locals.push Local::I32(typ, 0)...
          locals.push 0
        else
          $stderr.puts "warning: unknown type #{typ.inspect}. default to Object"
          locals.push Object.new
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
    # @rbs return: Object|nil
    def invoke_external(external_function)
      local_start = stack.size - external_function.callsig.size
      args = stack[local_start..]
      if args
        raise LoadError, "stack too short"
      end
      self.stack = drained_stack(local_start)

      proc = external_function.callable
      proc.call(self.instance.store, args)
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
      case insn.code
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

      when :i32_add
        right, left = stack.pop, stack.pop
        if !right.is_a?(Integer) || !left.is_a?(Integer)
          raise EvalError, "maybe empty stack"
        end
        stack.push(left + right)
      when :i32_const
        const = insn.operand[0]
        if !const.is_a?(Integer)
          raise EvalError, "[BUG] invalid type of operand"
        end
        stack.push(const)
      when :i32_store
        _align = insn.operand[0] # TODO: alignment support?
        offset = insn.operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)

        value = stack.pop
        addr = stack.pop
        if !value.is_a?(Integer) || !addr.is_a?(Integer)
          raise EvalError, "maybe stack too short"
        end

        at = addr + offset
        data_end = at + 4 # sizeof(i32)
        memory = self.instance.store.memories[0] || raise("[BUG] no memory")
        memory.data[at...data_end] = [value].pack("I")
        pp memory.data[at...data_end]

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

      when :end
        old_frame = call_stack.pop
        if !old_frame
          raise EvalError, "maybe empty call stack"
        end

        # unwind the stacks
        if old_frame.arity > 0
          if old_frame.arity > 1
            raise ::NotImplementedError, "return artiy >= 2 not yet supported ;;"
          end
          value = stack.pop
          if !value
            raise EvalError, "cannot obtain return value"
          end
          self.stack = drained_stack(old_frame.sp)
          stack.push value
        else
          self.stack = drained_stack(old_frame.sp)
        end
      end
    end

    # @rbs finish: Integer
    # @rbs return: Array[Object]
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

    attr_accessor :locals #: Array[Object]

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

            memory.data[data_start..data_end] = segment.data
            pp memory.data
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

    attr_accessor :max #: Integer|nil

    # @rbs min: Integer
    # @rbs max: Integer|nil
    # @rbs return: void
    def initialize(min, max)
      @data = String.new("\0" * (min * 64 * 1024), capacity: min * 64 * 1024)
      @max = max
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
end
