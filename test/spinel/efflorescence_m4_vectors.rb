# frozen_string_literal: true

require "wardite"
require_relative "efflorescence_m2_probe"

vm = File.open(ARGV.fetch(0), "rb") do |file|
  Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false, engine: :efflorescence).runtime
end
raise "wrong runtime" unless vm.is_a?(Wardite::Efflorescence::VM)

File.open(ARGV.fetch(1), "r") do |file|
  while line = file.gets
    fields = line.split
    name = fields.shift || raise("missing operation")
    expected = fields.pop || raise("missing expected result")
    arguments = fields.map { |field| field.to_i }
    begin
      actual = M2Probe.call(vm, name, arguments)
      matches = case expected
                when "void" then actual.nil?
                when "zero", "overflow", "bounds", "uncaught" then false
                else actual == expected.to_i
                end
      unless matches
        raise "#{name} #{arguments.inspect}: expected #{expected}, got #{actual}"
      end
    rescue Wardite::IntegerOverflow
      raise "unexpected overflow for #{name} #{arguments.inspect}" unless expected == "overflow"
    rescue Wardite::UncaughtWasmException => error
      raise error unless expected == "uncaught" && error.payload == [4294967295, arguments.fetch(0), 7]
    rescue Wardite::EvalError => error
      zero = expected == "zero" && error.message == "integer divide by zero"
      bounds = expected == "bounds" && error.message == "out of bounds memory access"
      raise error unless zero || bounds
    end
  end
end
puts "M4 vectors passed"
