# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_parity"

require_relative "support/efflorescence_helper"
require_relative "support/efflorescence_invalid_cases"

class EfflorescenceParityTest < Test::Unit::TestCase
  include EfflorescenceHelper
  include EfflorescenceInvalidCases

  test "reject invalid i32 immediates and unreferenced globals" do
    malformed_numeric_fixtures.each do |bytes, reason|
      [:stack, :efflorescence].each do |engine|
        error = assert_raise(Wardite::LoadError) do
          Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), engine: engine, enable_wasi: false)
        end
        assert_include error.message, reason
      end
    end
  end

  test "parity runner compares state and the position of a trap" do
    assert_nothing_raised do
      EfflorescenceParity.run([EfflorescenceParity.state_fixture], runtime: :cruby)
    end
  end

  test "parity comparison distinguishes exact bits and arithmetic NaNs" do
    compare = EfflorescenceParity.method(:result_matches?)
    assert_true compare.call("f32:qnan", "f32:2143289345")
    assert_false compare.call("f32:qnan", "f32:2139095041")
    assert_false compare.call("f32:2147483648", "f32:0")
    assert_false compare.call("f32:2143289345", "f32:2143289346")
  end
end
