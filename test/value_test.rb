# frozen_string_literal: true

require "test_helper"

class WarditeValueTest < Test::Unit::TestCase
  test "I32 normalizes wide positive and negative integers before caching" do
    assert_equal 42, Wardite::I32((1 << 100) + 42).value
    assert_equal 0xffffffff, Wardite::I32(-(1 << 100) - 1).value
    assert_equal 0, Wardite::I32(1 << 32).value
    assert_equal 0xffffffff, Wardite::I32(-1).value
    assert_same Wardite::I32(42), Wardite::I32((1 << 100) + 42)
  end
end
