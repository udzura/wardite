# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_parity"

class EfflorescenceParityTest < Test::Unit::TestCase
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
