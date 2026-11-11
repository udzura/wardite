# frozen_string_literal: true
# rbs_inline: enabled

require "wardite"

class ParityHost
  attr_reader :events #: Array[Integer]

  def initialize
    @events = []
  end

  # @rbs store: Wardite::Store
  # @rbs arguments: Array[Wardite::wasmValue]
  # @rbs return: Wardite::wasmFuncReturn
  def capture_i32(store, arguments)
    value = arguments.fetch(0)
    raise "record requires a boxed i32" unless value.is_a?(Wardite::I32)
    @events << value.value
    nil
  end

  # @rbs store: Wardite::Store
  # @rbs arguments: Array[Wardite::wasmValue]
  # @rbs return: Wardite::wasmFuncReturn
  def write_i32(store, arguments)
    capture_i32(store, arguments)
    puts "guest:#{@events.last}"
    nil
  end
end

class ParityWorker
  # @rbs value: Object?
  # @rbs return: String
  def self.encode(value)
    case value
    when Wardite::I32 then "i32:#{value.value & 0xffffffff}"
    when Wardite::I64 then "i64:#{value.value_s}"
    when Wardite::F32 then "f32:#{value.raw_bits}"
    when Wardite::F64 then "f64:#{value.raw_bits}"
    when nil then "void"
    else raise "unexpected result #{value.inspect}"
    end
  end

  # @rbs vm: Wardite::Efflorescence::VM
  # @rbs export: String
  # @rbs return: String
  def self.invoke_mir(vm, export)
    encode(vm.call(export, []))
  rescue Wardite::UncaughtWasmException => error
    types = error.tag.parameter_types
    fields = [] #: Array[String]
    error.payload.each_with_index do |value, index|
      type = types.fetch(index)
      bits = value.is_a?(Float) ? Wardite::FloatBits.from_float(type, value) : value
      fields << "#{type}:#{bits}"
    end
    "exception:#{fields.join(',')}"
  end

  # @rbs vm: Wardite::Runtime
  # @rbs export: String
  # @rbs return: String
  def self.invoke_stack(vm, export)
    encode(vm.call(export, []))
  end

  # @rbs runtime: Wardite::Runtime | Wardite::Efflorescence::VM
  # @rbs export: String
  # @rbs return: String
  def self.invoke(runtime, export)
    if runtime.is_a?(Wardite::Efflorescence::VM)
      invoke_mir(runtime, export)
    elsif runtime.is_a?(Wardite::Runtime)
      invoke_stack(runtime, export)
    else
      raise "missing runtime"
    end
  rescue Wardite::Unreachable
    "trap:unreachable"
  rescue Wardite::IntegerOverflow
    "trap:overflow"
  rescue ZeroDivisionError
    "trap:zero"
  rescue FloatDomainError
    "trap:float_domain"
  rescue Wardite::EvalError => error
    message = error.message
    return "trap:zero" if message.include?("divide by zero") || message.include?("division by zero")
    return "trap:invalid" if message.include?("invalid conversion to integer")
    return "trap:bounds" if message.include?("out of bounds memory access") || message.include?("invalid memory range")
    return "trap:indirect" if message.include?("call_indirect") || message.start_with?("uninitialized element")
    raise error unless runtime.is_a?(Wardite::Runtime)
    "legacy_error:#{message.gsub(/\s+/, ' ')}"
  rescue StandardError => error
    raise error unless runtime.is_a?(Wardite::Runtime)
    message = error.message
    return "trap:bounds" if message.start_with?("broken string or unsupported size:") || message == "invalid float bytes"
    "legacy_error:#{error.class}:#{error.message.gsub(/\s+/, ' ')}"
  end

  # @rbs store: Wardite::Store
  # @rbs windows: String
  # @rbs return: String
  def self.memory(store, windows)
    memory = store.memories.first
    return "-" unless memory

    bytes = [] #: Array[String]
    windows.split(",").each do |window|
      next if window == "-"
      parts = window.split(":")
      start, length = parts.fetch(0).to_i, parts.fetch(1).to_i
      slice = memory.data.byteslice(start, length) || ""
      encoded = slice.unpack1("H*")
      raise "cannot encode memory" unless encoded.is_a?(String)
      bytes << encoded
    end
    "#{memory.current}:#{memory.data.bytesize}:#{bytes.join(',')}"
  end

  # @rbs vm: Wardite::Efflorescence::VM
  # @rbs return: String
  def self.dispatches(vm)
    names = Wardite::Efflorescence::Opcode::NAMES
    counts = vm.metrics.opcode_counts
    executed = [] #: Array[String]
    index = 0
    while index < names.size
      executed << names.fetch(index) if counts.fetch(index) > 0
      index += 1
    end
    executed.join(",")
  end

  # @rbs output: File
  # @rbs fields: Array[String]
  # @rbs engine: Symbol
  # @rbs disabled: Array[Symbol]
  # @rbs return: void
  def self.observe(output, fields, engine, disabled)
    id, path, exports, windows = fields.fetch(0), fields.fetch(1), fields.fetch(2), fields.fetch(3)
    host = ParityHost.new
    imports = Wardite::HashModule.new({
      capture_i32: ->(store, arguments) { host.capture_i32(store, arguments) },
      write_i32: ->(store, arguments) { host.write_i32(store, arguments) }
    })
    begin
      instance = File.open(path, "rb") do |file|
        Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false, engine: engine,
          import_object: { env: imports }, mir_profile: true, disabled_optimizations: disabled)
      end
    rescue Wardite::LoadError => error
      raise error unless exports == "-"
      output.puts([id, "-", "load:#{error.message}", "-", "", host.events.join(","), "-"].join("\t"))
      return
    rescue NameError => error
      raise error unless exports == "-"
      output.puts([id, "-", "link:#{error.message}", "-", "", host.events.join(","), "-"].join("\t"))
      return
    rescue Wardite::Unreachable => error
      raise error unless exports == "-"
      output.puts([id, "-", "trap:unreachable", "-", "", host.events.join(","), "-"].join("\t"))
      return
    end
    if exports == "-"
      output.puts([id, "-", "load:success", "-", "", host.events.join(","), "-"].join("\t"))
      return
    end
    runtime = instance.runtime
    store = instance.store
    exports.split(",").each do |name|
      result = invoke(runtime, name)
      counts = runtime.is_a?(Wardite::Efflorescence::VM) ? dispatches(runtime) : "-"
      globals = store.globals.map { |global| encode(global.value) }.join(",")
      output.puts([id, name, result, memory(store, windows), globals, host.events.join(","), counts].join("\t"))
    end
  end
end

if ARGV.fetch(0) == "wasi-rejection"
  [:stack, :efflorescence].each do |engine|
    begin
      File.open(ARGV.fetch(1), "rb") do |file|
        Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: true, engine: engine)
      end
      raise "Spinel accepted WASI"
    rescue Wardite::LoadError => error
      raise error unless error.message.include?("WASI is not supported in Spinel builds")
    end
  end
  puts "Spinel WASI rejection passed"
else
  engine = ARGV.fetch(0).to_sym
  disabled = ARGV.fetch(3).split(",").map { |value| value.to_sym }
  File.open(ARGV.fetch(2), "w") do |output|
    File.open(ARGV.fetch(1), "r") do |input|
      while row = input.gets
        ParityWorker.observe(output, row.chomp.split("\t"), engine, disabled)
      end
    end
  end
end
