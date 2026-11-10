# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"
require_relative "support/efflorescence_m5_cases"

class EfflorescenceM5Test < Test::Unit::TestCase
  include EfflorescenceHelper
  include EfflorescenceM5Cases

  test "all float ALU operations match the bit vectors" do
    Dir.mktmpdir("wardite-m5-alu") do |dir|
      wat, vectors = float_vectors(float_alu_cases)
      wasm = File.join(dir, "alu.wasm")
      expected = File.join(dir, "vectors.txt")
      File.binwrite(wasm, compile_efflorescence_wat(wat))
      File.write(expected, vectors)
      output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "test/spinel/efflorescence_m5_vectors.rb", wasm, expected)
      assert status.success?, output
      assert_equal "M5 vectors passed\n", output
    end
  end

  test "float bit and rounding probes on CRuby" do
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "test/spinel/efflorescence_m5_bits.rb")
    assert status.success?, output
    assert_equal "M5 float bit and rounding probes passed\n", output
  end

  test "float control and public API on CRuby" do
    Dir.mktmpdir("wardite-m5-control") do |dir|
      wasm = File.join(dir, "control.wasm")
      wat = File.read(File.join(__dir__, "fixtures/efflorescence/m5_control.wat"))
      File.binwrite(wasm, compile_efflorescence_wat(wat))
      output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "test/spinel/efflorescence_m5_control.rb", wasm)
      assert status.success?, output
      assert_equal "M5 float control passed\n", output
    end
  end

  test "decoder retains NaN immediates and Stack VM can still read floats" do
    wasm = compile_efflorescence_wat(<<~WAT)
      (module
        (func (export "f32") (result f32) f32.const -nan:0x123)
        (func (export "f64") (result f64) f64.const -0x0p+0)
        (global f32 (f32.const 0x1p-149)))
    WAT
    instance = Wardite::BinaryLoader.load_from_buffer(StringIO.new(wasm), enable_wasi: false)
    code = instance.code_section.func_codes.first.body.first
    assert_equal 0xff800123, code[2].first.bits
    assert_predicate instance.runtime.call("f32", []).value, :nan?
    assert_equal(-Float::INFINITY, 1.0 / instance.runtime.call("f64", []).value)
    assert_equal 2.0**-149, instance.store.globals.first.value.value
  end
end
