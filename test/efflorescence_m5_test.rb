# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"

class EfflorescenceM5Test < Test::Unit::TestCase
  include EfflorescenceHelper

  test "float bit and rounding probes on CRuby" do
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "test/spinel/efflorescence_m5_bits.rb")
    assert status.success?, output
    assert_equal "M5 float bit and rounding probes passed\n", output
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
