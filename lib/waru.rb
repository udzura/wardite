# frozen_string_literal: true
# rbs_inline: enabled

require_relative "waru/version"
require_relative "waru/leb128"
require_relative "waru/const"
require_relative "waru/instruction"

require "stringio"

module Waru
  class Section
    attr_accessor :name
   
    attr_accessor :code

    attr_accessor :size
  end

  class TypeSection < Section
    attr_accessor :defined_types

    attr_accessor :defined_results

    def initialize
      self.name = "Type"
      self.code = 0x1

      @defined_types = []
      @defined_results = []
    end
  end

  class FunctionSection < Section
    attr_accessor :func_indices

    def initialize
      self.name = "Function"
      self.code = 0x3

      @func_indices = []
    end
  end

  class CodeSection < Section
    class CodeBody
      # @rbs locals: Array[Integer]
      attr_accessor :locals_count
      # @rbs locals: Array[Integer]
      attr_accessor :locals_type
      # @rbs body: Array[Integer]
      attr_accessor :body
      def initialize(&blk)
        blk.call(self)
      end
    end
    # @rbs func_codes: Array[CodeBody]
    attr_accessor :func_codes

    def initialize
      self.name = "Code"
      self.code = 0xa

      @func_codes = []
    end
  end

  class ExportSection < Section
    class ExportDesc
      attr_accessor :name
      
      attr_accessor :kind

      attr_accessor :func_index
    end

    # @rbs @exports: Hash[String, ExportDesc]
    attr_accessor :exports

    def initialize
      self.name = "Export"
      self.code = 0x7

      @exports = {}
    end

    def add_desc(&blk)
      desc = ExportDesc.new
      blk.call(desc)
      self.exports[desc.name] = desc
    end
  end

  module BinaryLoader
    extend Waru::Leb128Helpers

    # @rbs buf: File|StringIO
    # @rbs return: Instance
    def self.load_from_buffer(buf)
      @buf = buf #: File

      version = preamble
      sections_ = sections
      # TBA...

      return Instance.new do |i|
        i.version = version
        i.sections = sections_
      end
    end

    # @rbs return: Integer
    def self.preamble
      asm = @buf.read 4
      if asm != "\u0000asm"
        raise LoadError, "invalid preamble"
      end

      version = @buf.read(4)
        .to_enum(:chars)
        .with_index
        .inject(0) {|dest, (c, i)| dest | (c.ord << i*8) }
      if version != 1
        raise LoadError, "unsupported version: #{version}"
      end
      version
    end

    # @rbs return: []Section
    def self.sections
      sections = []

      loop do
        byte = @buf.read(1)
        if byte == nil
          break
        end
        code = byte.unpack("C")[0]

        section = case code
          when Waru::SectionType
            type_section
          when Waru::SectionImport
            unimplemented_skip_section(code)
          when Waru::SectionFunction
            function_section
          when Waru::SectionTable
            unimplemented_skip_section(code)
          when Waru::SectionMemory
            unimplemented_skip_section(code)
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
            unimplemented_skip_section(code)
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
      sbuf = StringIO.new(@buf.read(size))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        fncode = assert_read(sbuf, 1)
        if fncode != "\x60"
          raise LoadError, "not a function definition"
        end

        arglen = fetch_uleb128(sbuf)
        arg = []
        arglen.times do
          case ty = assert_read(sbuf, 1).unpack("C")[0]
          when 0x7f
            arg << :i32
          when 0x7e
            arg << :i64
          else
            raise NotImplementedError, "unsupported for now: #{ty.to_s(16).inspect}"
          end
        end
        dest.defined_types << arg

        retlen = fetch_uleb128(sbuf)
        ret = []
        retlen.times do
          case ty = assert_read(sbuf, 1).unpack("C")[0]
          when 0x7f
            ret << :i32
          when 0x7e
            ret << :i64
          else
            raise NotImplementedError, "unsupported for now: #{ty.to_s(16).inspect}"
          end
        end
        dest.defined_results << ret
      end

      dest
    end

    # @rbs return: FunctionSection
    def self.function_section
      dest = FunctionSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(@buf.read(size))

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
      sbuf = StringIO.new(@buf.read(size))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        ilen = fetch_uleb128(sbuf)
        code = assert_read(sbuf, ilen)
        if code[-1].ord != 0x0b
          $stderr.puts "warning: instruction not ended with inst end(0x0b): 0x0#{code[-1].ord.to_s(16)}" 
        end
        cbuf = StringIO.new(code)
        locals_count = []
        locals_type = []
        locals_len = fetch_uleb128(cbuf)
        locals_len.times do
          type_count = fetch_uleb128(cbuf)
          locals_count << type_count
          value_type = assert_read(cbuf, 1).unpack("C*")[0]
          locals_type << value_type
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

    # @rbs return: ExportSection
    def self.export_section
      dest = ExportSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(@buf.read(size))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        nlen = fetch_uleb128(sbuf)
        name = assert_read(sbuf, nlen)
        kind = assert_read(sbuf, 1).unpack("C")[0]
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
      $stderr.puts "warning: unimplemented section: 0x0#{code.to_s(16)}"
      size = @buf.read(1).unpack("C")[0]
      @buf.read(size)
      nil
    end

    # @rbs sbuf: StringIO
    # @rbs n: Integer
    # @rbs return: String
    def self.assert_read(sbuf, n)
      ret = sbuf.read n
      if ret == nil || ret.size != n
        raise LoadError, "too short section size"
      end
      ret
    end
  end

  class Instance
    # @rbs @version: Integer
    attr_accessor :version

    # @rbs @sections: Array[Section]
    attr_accessor :sections

    attr_accessor :runtime

    attr_accessor :store

    attr_accessor :exports

    def initialize(&blk)
      blk.call(self)

      @store = Store.new(self)
      @exports = Exports.new(self.export_section, store)
      @runtime = Runtime.new(self)
    end

    def type_section
      @sections.find{|s| s.code == Waru::Const::SectionType }
    end

    def function_section
      @sections.find{|s| s.code == Const::SectionFunction }
    end

    def code_section
      @sections.find{|s| s.code == Const::SectionCode }
    end

    def export_section
      @sections.find{|s| s.code == Const::SectionExport }
    end
  end

  class Runtime
    attr_accessor :stack

    attr_accessor :call_stack

    def initialize(inst)
      @stack = []
      @call_stack = []
      @instance = inst
    end

    def callable?(name)
      !! @instance.exports[name.to_s]
    end

    def call(name, args)
      if !callable?(name)
        raise NoMethodError "function #{name} not found"
      end
      kind, fn = @instance.exports[name.to_s]
      if kind != 0
        raise NoMethodError "#{name} is not a function"
      end
      if fn.callsig.size != args.size
        raise ArgumentError, "unmatch arg size"
      end
      args.each do |arg|
        stack.push arg
      end

      invoke_internal(fn)
    end

    def call_index(idx, args)
      fn = @instance.store[idx]
      if !fn
        # TODO: own error NoFunctionError
        raise NoMethodError, "func #{idx} not found"
      end
      if fn.callsig.size != args.size
        raise ArgumentError, "unmatch arg size"
      end
      args.each do |arg|
        stack.push arg
      end

      invoke_internal(fn)
    end

    def invoke_internal(fn)
      local_start = stack.size - fn.callsig.size
      locals = stack[local_start..]
      self.stack = stack[0...local_start]

      fn.locals_type.each_with_index do |typ, i|
        case typ
        when :i32, :u32
          # locals.push Local::I32(typ, 0)...
          locals.push 0
        else
          $stderr.puts "warning: unknown type #{typ.inspect}. default to Object"
          locals.push Object.new
        end
      end

      arity = fn.retsig.size
      frame = Frame.new(-1, stack.size, fn.body, arity, locals)
      self.call_stack.push(frame)

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

    def eval_insn(frame, insn)
      case insn.code
      when :local_get
        idx = insn.operand[0]
        local = frame.locals[idx]
        if !local
          raise EvalError, "local not found"
        end
        stack.push(local)
      when :i32_add
        right, left = stack.pop, stack.pop
        if !right || !left
          raise EvalError, "maybe empty stack"
        end
        stack.push(left + right)

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
          self.stack = stack[0...old_frame.sp]
          stack.push value
        else
          self.stack = stack[0...old_frame.sp]
        end
      end
    end

    def method_missing(name, *args)
      if callable? name
        call(name, args)
      else
        super
      end
    end

    def respond_to? name
      callable?(name) || super
    end
  end

  class Frame
    attr_accessor :pc, :sp

    attr_accessor :body

    attr_accessor :arity

    attr_accessor :locals

    def initialize(pc, sp, body, arity, locals)
      @pc = pc
      @sp = sp
      @body = body
      @arity = arity
      @locals = locals
    end
  end

  class Store
    attr_accessor :funcs
    def initialize(inst)
      type_section = inst.type_section
      func_section = inst.function_section
      code_section = inst.code_section
      @funcs = []

      func_section.func_indices.each_with_index do |findex, sigindex|
        callsig = type_section.defined_types[sigindex]
        retsig = type_section.defined_results[sigindex]
        codes = code_section.func_codes[findex]
        fn = WasmFunction.new(callsig, retsig, codes)
        self.funcs << fn
      end
    end

    def [](idx)
      @funcs[idx]
    end
  end

  class Exports
    # @rbs mappings: Hash[String, WasmFunction]
    attr_accessor :mappings
    def initialize(export_section, store)
      @mappings = {}
      export_section.exports.each_pair do |name, desc|
        # TODO: introduce map by kind
        @mappings[name] = [desc.kind, store.funcs[desc.func_index]]
      end
    end

    def [](name)
      @mappings[name]
    end

    def method_missing(name, *args)
      if fn = @mappings[name]
        fn       
      else
        super
      end
    end
  end

  class WasmFunction
    attr_accessor :callsig

    attr_accessor :retsig

    attr_accessor :code_body

    def initialize(callsig, retsig, code_body)
      @callsig = callsig
      @retsig = retsig

      @code_body = code_body
    end

    def body
      code_body.body
    end

    def locals_type
      code_body.locals_type
    end    

    def locals_count
      code_body.locals_count
    end    
  end

  class LoadError < StandardError; end
  class ArgumentError < StandardError; end
  class EvalError < StandardError; end
end
