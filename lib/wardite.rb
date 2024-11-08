# frozen_string_literal: true
# rbs_inline: enabled

require_relative "wardite/version"
require_relative "wardite/leb128"
require_relative "wardite/const"
require_relative "wardite/instruction"
require_relative "wardite/value"
require_relative "wardite/load"

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
          frame.pc = fetch_ops_while_else_or_end(frame.body, frame.pc)
        end

        if frame.pc == next_pc
          # This means if block has no else instr.
          return
        end

        label = Label.new(:if, next_pc, stack.size, block.result_size)
        frame.labels.push(label)

      when :else
        if old_label = frame.labels.pop
          frame.pc = old_label.pc
          stack_unwind(old_label.sp, old_label.arity)
        else
          raise EvalError, "else should be in if block"
        end

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

      when :local_tee
        idx = insn.operand[0]
        if !idx.is_a?(Integer)
          raise EvalError, "[BUG] invalid type of operand"
        end
        value = stack.pop
        if !value
          raise EvalError, "value should be pushed"
        end
        frame.locals[idx] = value
        stack.push value

      when :global_get
        idx = insn.operand[0]
        if !idx.is_a?(Integer)
          raise EvalError, "[BUG] invalid type of operand"
        end
        global = instance.store.globals[idx]
        if !global
          raise EvalError, "global not found"
        end
        stack.push(global.value)

      when :global_set
        idx = insn.operand[0]
        if !idx.is_a?(Integer)
          raise EvalError, "[BUG] invalid type of operand"
        end
        current_global = instance.store.globals[idx]
        if !current_global
          raise EvalError, "global index not valid"
        end
        if !current_global.mutable?
          raise EvalError, "global not mutable"
        end
        value = stack.pop
        if !value
          raise EvalError, "value should be pushed"
        end
        current_global.value = value
        instance.store.globals[idx] = current_global

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
    def fetch_ops_while_else_or_end(ops, pc_start)
      cursor = pc_start
      depth = 0
      loop {
        cursor += 1
        inst = ops[cursor]
        case inst&.code
        when nil
          raise EvalError, "end op not found"
        when :if
          depth += 1
        when :else
          if depth == 0
            return cursor
          end
          # do not touch depth
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

    attr_accessor :globals #: Array[Global]

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

      @globals = []
      global_section = inst.global_section
      if global_section
        global_section.globals.each do |g|
          @globals << Global.new do |g2|
            g2.type = g.type
            g2.mutable = g.mutable
            g2.shared = g.shared
            g2.value = g.value
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

  class Global
    attr_accessor :type #: Symbol
    
    attr_accessor :mutable #: bool

    # TODO: unused in wasm 1.0 spec?
    attr_accessor :shared #: bool

    attr_accessor :value #: I32|I64|F32|F64

    # @rbs &blk: (Global) -> void
    # @rbs return: void
    def initialize(&blk)
      blk.call(self)
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
