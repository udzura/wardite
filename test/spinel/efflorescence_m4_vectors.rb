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
      if expected == "zero" || expected == "overflow" || actual != expected.to_i
        raise "#{name} #{arguments.inspect}: expected #{expected}, got #{actual}"
      end
    rescue Wardite::IntegerOverflow
      raise "unexpected overflow for #{name} #{arguments.inspect}" unless expected == "overflow"
    rescue Wardite::EvalError => error
      raise error unless expected == "zero" && error.message == "integer divide by zero"
    end
  end
end
puts "M4 vectors passed"
