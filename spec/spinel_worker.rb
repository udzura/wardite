# frozen_string_literal: true

require_relative "spectest_host"

# One process owns one WAST script's instances and executes its commands in order.
class SpecWorker
  def initialize
    @externals = {} #: Hash[Integer, Wardite::ExternalReference]
    @imports = {spectest: SpectestHost.new} #: Hash[Symbol, Wardite::wasmModuleSrc]
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
    if op == "instantiate" || op == "unlinkable" || op == "module" || op == "invalid" || op == "malformed"
      begin
        instance = Wardite.new(path: operand, engine: :efflorescence, enable_wasi: false,
          import_object: @imports)
      rescue Wardite::LinkError
        raise unless op == "invalid"
        # Validate the body with its declared imports even if a host is absent.
        instance = Wardite.new(path: operand, enable_wasi: false, emit_wmir: "#{operand}.wmir")
      end
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
    when "active element segment out of bounds"
      "trap:out of bounds table access"
    when "active data segment out of bounds"
      "trap:out of bounds memory access"
    when "constant expression requires end", "global initializer type mismatch"
      "validation:#{message}"
    when "data count section required", "integer representation too long", "integer too large", "section size mismatch",
         "unexpected end", "length out of bounds", "END opcode expected", "malformed section id",
         "too many locals", "unexpected content after last section", "malformed reference type",
         "malformed memop flags", "malformed UTF-8 encoding"
      "malformed:#{message}"
    when "unsigned LEB128 exceeds width", "signed LEB128 exceeds width" then "malformed:integer too large"
    when "invalid data segment count" then "malformed:data count and data section have inconsistent lengths"
    when "function and code section lengths differ" then "malformed:function and code section have inconsistent lengths"
    when "unsupported table limits", "shared/memory64/custom-page memory limits are not supported" then "malformed:malformed limits flags"
    when "invalid preamble" then "malformed:magic header not detected"
    when /\Aunsupported version:/ then "malformed:unknown binary version"
    when /\Aunsupported import kind/ then "malformed:malformed import kind"
    when /\Aunsupported code: (\d+)/ then "malformed:illegal opcode #{message.split.last.to_i.to_s(16)}"
    when /\Atrailing .* (bytes|data)/ then "malformed:section size mismatch"
    when "buffer too short", "unterminated constant expression", "unterminated structured control", "too short section size", "invalid or truncated unsigned LEB128"
      "malformed:unexpected end"
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
    message = message.sub("call_indirect null reference ", "uninitialized element ") if message.start_with?("call_indirect null reference ")
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
