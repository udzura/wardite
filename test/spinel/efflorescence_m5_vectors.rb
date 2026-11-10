# frozen_string_literal: true
# rbs_inline: enabled

require "wardite"

class M5Vectors
  # @rbs vm: Wardite::Efflorescence::VM
  # @rbs name: String
  # @rbs type: String
  # @rbs expected: String
  # @rbs return: void
  def self.verify(vm, name, type, expected)
    actual = vm.call_unboxed(name, [])
    matches = if actual.is_a?(Float)
                bits = Wardite::FloatBits.from_float(type == "f32" ? :f32 : :f64, actual)
                if expected == "nan"
                  quiet_nan = type == "f32" ? 0x7fc00000 : 0x7ff8000000000000
                  (bits & quiet_nan) == quiet_nan
                else
                  bits == expected.to_i
                end
              else
                expected != "nan" && actual == expected.to_i
              end
    raise "#{name}: expected #{expected}, got #{actual.inspect}" unless matches && expected != "overflow" && expected != "invalid"
  rescue Wardite::IntegerOverflow => error
    raise error unless expected == "overflow"
  rescue Wardite::EvalError => error
    raise error unless expected == "invalid" && error.message == "invalid conversion to integer"
  end
end

[[], [:all], [:frames]].each do |disabled|
  vm = File.open(ARGV.fetch(0), "rb") do |file|
    Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false, engine: :efflorescence,
      disabled_optimizations: disabled, mir_profile: true).runtime
  end
  raise "wrong runtime" unless vm.is_a?(Wardite::Efflorescence::VM)
  File.open(ARGV.fetch(1), "r") do |file|
    while line = file.gets
      fields = line.split
      name, type, op, expected = fields.fetch(0), fields.fetch(1), fields.fetch(2), fields.fetch(3)
      M5Vectors.verify(vm, name, type, expected)
      index = Wardite::Efflorescence::Opcode::NAMES.index(op)
      raise "#{name}: #{op} did not execute" unless index && vm.metrics.opcode_counts.fetch(index) > 0
    end
  end
end
puts "M5 vectors passed"
