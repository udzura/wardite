# frozen_string_literal: true

# Usage: bundle exec ruby -Ilib benchmark/validate_m5.rb
require "wardite"
require "open3"
require "tmpdir"
require_relative "../test/support/efflorescence_m5_cases"

include EfflorescenceM5Cases

def capture!(*command)
  output, error, status = Open3.capture3(*command)
  abort "#{command.inspect}\n#{output}#{error}" unless status.success?
  output.strip
end

def random_cases(fixed)
  random = Random.new(0x20261110)
  fixed.group_by(&:first).flat_map do |op, vectors|
    code = Wardite::Efflorescence::Translator::FLOAT_ALU.fetch(op.tr(".", "_").to_sym)
    result, *inputs = Wardite::Efflorescence::Opcode::FLOAT_ALU_TYPES.fetch(code)
    Array.new(8) do
      operands = inputs.map do |type|
        width = Integer(type.to_s[1..])
        bits = random.rand(1 << width)
        if type.start_with?("f")
          "#{type.to_s.sub('f', 'i')}.const #{bits} #{type}.reinterpret_i#{width}"
        else
          "#{type}.const #{bits}"
        end
      end.join(" ")
      [op, operands, result.to_s, nil]
    end
  end
end

def allowed_nan?(value, type)
  mask = type == "f32" ? 0x7fc00000 : 0x7ff8000000000000
  (value & mask) == mask
end

def trap_reason(stderr)
  return "overflow" if stderr.include?("integer overflow")
  return "invalid" if stderr.include?("invalid conversion to integer")
  abort stderr
end

def wardite_result(vm, name)
  vm.call_unboxed(name, [])
rescue Wardite::IntegerOverflow
  "overflow"
rescue Wardite::EvalError => error
  raise unless error.message == "invalid conversion to integer"
  "invalid"
end

puts capture!("wasmtime", "--version")
puts capture!("wasm-tools", "--version")
Dir.mktmpdir("wardite-m5-reference") do |dir|
  fixed = float_alu_cases + float_conversion_cases
  cases = fixed + random_cases(fixed)
  # Reinterpret in Wasm so neither the reference CLI nor the public Ruby Float
  # boundary can discard a NaN payload before comparison.
  exports = cases.each_with_index.map do |(op, operands, type, _), i|
    float = type.start_with?("f")
    output_type = float ? type.sub("f", "i") : type
    conversion = float ? "#{output_type}.reinterpret_#{type}" : ""
    %((func (export "case#{i}") (result #{output_type}) #{operands} #{op} #{conversion}))
  end
  wat = File.join(dir, "cases.wat")
  wasm = File.join(dir, "cases.wasm")
  File.write(wat, "(module #{exports.join("\n")})")
  capture!("wasm-tools", "parse", wat, "-o", wasm)
  capture!("wasm-tools", "validate", wasm)
  vm = Wardite.new(path: wasm, enable_wasi: false, engine: :efflorescence, disabled_optimizations: [:all]).runtime
  cases.each_with_index do |(op, operands, type, expected), i|
    name = "case#{i}"
    output, stderr, status = Open3.capture3("wasmtime", "run", "--invoke", name, wasm)
    reference = if status.success?
                  bits = Integer(output)
                  type.end_with?("32") ? bits & 0xffffffff : bits
                else
                  trap_reason(stderr)
                end
    actual = wardite_result(vm, name)
    arithmetic = type.start_with?("f") && !op.match?(/\.(?:abs|neg|copysign|reinterpret_.+)\z/)
    matches = if arithmetic && reference.is_a?(Integer) && allowed_nan?(reference, type)
                actual.is_a?(Integer) && allowed_nan?(actual, type)
              else
                actual == reference
              end
    abort "#{op} (#{operands}): Wasmtime #{reference}, Efflorescence #{actual}" unless matches
    abort "#{op}: expected #{expected}, Wasmtime #{reference}" if expected.is_a?(Integer) && reference != expected
  end
  puts "#{fixed.size} fixed and #{cases.size - fixed.size} seeded bit vectors agree (#{fixed.map(&:first).uniq.size} ALU and conversion opcodes)"

  source = File.expand_path("../test/fixtures/efflorescence/m5_store_eh.wat", __dir__)
  capture!("wasm-tools", "parse", source, "-o", wasm)
  capture!("wasm-tools", "validate", wasm)
  vm = Wardite.new(path: wasm, enable_wasi: false, engine: :efflorescence).runtime
  %w[global32 global64 eh].each do |name|
    expected = Integer(capture!("wasmtime", "run", "-W", "exceptions=y", "--invoke", name, wasm))
    expected &= 0xffffffff if name == "global32"
    actual = vm.call_unboxed(name, [])
    abort "#{name}: Wasmtime #{expected}, Efflorescence #{actual}" unless actual == expected
  end
  puts "raw global initializers and mixed EH agree"
end
