# frozen_string_literal: true

require "wardite"

# One process owns one WAST script's instances and executes its commands in order.
class SpecWorker
  def initialize
    @externals = {} #: Hash[Integer, Wardite::ExternalReference]
    @imports = {} #: Hash[Symbol, Wardite::wasmModuleSrc]
    @instances = {} #: Hash[String, Wardite::Instance]
  end

  def encode(value)
    case value
    when Array then value.map { |item| encode(item) }.join(",")
    when Wardite::I32 then "i32:#{value.value}"
    when Wardite::I64 then "i64:#{value.value_s}"
    when Wardite::F32 then "f32:#{value.raw_bits}"
    when Wardite::F64 then "f64:#{value.raw_bits}"
    when Wardite::ExternalReference then "externref:#{value.value}"
    when Wardite::FunctionReference then "funcref"
    when nil then "void"
    else raise "unexpected result"
    end
  end

  def execute(fields)
    op, id, operand = fields.fetch(0), fields.fetch(1), fields.fetch(2)
    if op == "register"
      @imports[operand.to_sym] = @instances.fetch(id).as_import_module
      return "registered"
    end
    if op == "unlinkable" || op == "module" || op == "invalid" || op == "malformed"
      global = Wardite::Global.numeric(:i32, false)
      global.value = Wardite::I32(666)
      wide = Wardite::Global.numeric(:i64, false)
      wide.value = Wardite::I64(666)
      spectest = Wardite::HashModule.new({}, {global_i32: global, global_i64: wide})
      @imports[:spectest] ||= spectest
      instance = Wardite.new(path: operand, engine: :efflorescence, enable_wasi: false,
        import_object: @imports)
      instance.runtime.prepare_all
      @instances[id] = instance if op == "module"
      return "loaded"
    end

    instance = @instances.fetch(id)
    if op == "get"
      export = instance.export_section.exports.fetch(operand)
      raise "not a global" unless export.kind == 3
      value = instance.store.globals.fetch(export.index).value
      return value.nil? ? "refnull" : encode(value)
    end
    arguments = [] #: Array[Object]
    fields.drop(3).each do |arg|
      parts = arg.split(":")
      if arg == "refnull"
        arguments << nil
        next
      end
      bits = parts.fetch(1).to_i
      case parts.fetch(0)
      when "externref" then arguments << (@externals[bits] ||= Wardite::ExternalReference.new(bits))
      when "f32" then arguments << Wardite::F32.from_bits(bits)
      when "f64" then arguments << Wardite::F64.from_bits(bits)
      else arguments << bits
      end
    end
    result = instance.runtime.call(operand, arguments)
    if result.nil?
      export = instance.export_section.exports.fetch(operand)
      function = instance.store.funcs.fetch(export.index)
      return "refnull" unless function.retsig.empty?
    end
    encode(result)
  rescue Wardite::LinkError => error
    "unlinkable:#{error.message}"
  rescue Wardite::InvalidModule, Wardite::InvalidInitializer, Wardite::Efflorescence::TranslationError => error
    "validation:#{error.message}"
  rescue Wardite::LoadError => error
    message = error.message
    # These loader checks implement Core validation before MIR translation.
    case message
    when "constant expression requires end", "global initializer type mismatch"
      "validation:#{message}"
    when "malformed memop flags"
      "malformed:#{message}"
    when "unsupported global mutability flags"
      "malformed:invalid mutability"
    else
      return "validation:#{message}" if message.start_with?("invalid element function index ")
      "error:#{error.class}: #{message}"
    end
  rescue Wardite::UncaughtWasmException
    "uncaught exception"
  rescue Wardite::IntegerOverflow
    "trap:integer overflow"
  rescue Wardite::Unreachable
    "trap:unreachable"
  rescue Wardite::EvalError => error
    message = error.message
    message = "undefined element" if message.start_with?("call_indirect table index out of bounds:")
    message = "uninitialized element" if message == "call_indirect null reference"
    message = "indirect call type mismatch" if message == "call_indirect function type mismatch"
    "trap:#{message}"
  rescue StandardError => error
    "error:#{error.class}: #{error.message}"
  end
end

worker = SpecWorker.new
File.open(ARGV.fetch(1), "w") do |output|
  File.foreach(ARGV.fetch(0)) do |row|
    output.puts worker.execute(row.chomp.split("\t")).gsub("\n", " ")
    output.flush
  end
end
