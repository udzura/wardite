# frozen_string_literal: true

require "test_helper"

class WarditeValueTest < Test::Unit::TestCase
  test "I32 multiplication wraps without a wide intermediate product" do
    values = [0, 1, 0xffff, 0x10000, 0x10001, 0x7fffffff, 0x80000000, 0xffffffff]
    values.product(values).each do |left, right|
      expected = (left * right) & 0xffffffff
      assert_equal expected, Wardite::I32(left).multiply(Wardite::I32(right)).value
    end
  end

  test "I32 normalizes wide positive and negative integers before caching" do
    assert_equal 42, Wardite::I32((1 << 100) + 42).value
    assert_equal 0xffffffff, Wardite::I32(-(1 << 100) - 1).value
    assert_equal 0, Wardite::I32(1 << 32).value
    assert_equal 0xffffffff, Wardite::I32(-1).value
    assert_same Wardite::I32(42), Wardite::I32((1 << 100) + 42)
  end
end
