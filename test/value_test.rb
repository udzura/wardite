# frozen_string_literal: true

require "test_helper"

class WarditeValueTest < Test::Unit::TestCase
  test "I64 left shifts discard high bits before shifting" do
    [0, 1, 0xffffffff, 0x7fffffffffffffff, 0x8000000000000000, 0xffffffffffffffff].each do |value|
      [0, 1, 31, 32, 63, 64, 65].each do |count|
        expected = (value << (count % 64)) & 0xffffffffffffffff
        assert_equal expected, Wardite::I64(value).shift_left(count).value
      end
    end
  end

  test "I64 addition carries and wraps at both word boundaries" do
    values = [0, 1, 0xffffffff, 0x100000000,
              0x7fffffffffffffff, 0x8000000000000000, 0xffffffffffffffff]
    values.product(values).each do |left, right|
      expected = (left + right) & 0xffffffffffffffff
      assert_equal expected, Wardite::I64(left).add(Wardite::I64(right)).value
    end
  end

  test "I64 multiplication wraps without a wide intermediate product" do
    values = [0, 1, 0xffff, 0x10000, 0xffffffff, 0x100000000,
              0x7fffffffffffffff, 0x8000000000000000, 0xffffffffffffffff]
    values.product(values).each do |left, right|
      expected = (left * right) & 0xffffffffffffffff
      assert_equal expected, Wardite::I64(left).multiply(Wardite::I64(right)).value
    end
  end

  test "I64 normalizes wide integers and preserves unsigned 64-bit values" do
    [0, 0x7fffffffffffffff, 0x8000000000000000, 0xffffffffffffffff].each do |value|
      assert_equal value, Wardite::I64(value).value
    end
    assert_equal 0xffffffffffffffff, Wardite::I64(-1).value
    assert_equal 42, Wardite::I64((1 << 100) + 42).value
    assert_equal 0xffffffffffffffff, Wardite::I64(-(1 << 100) - 1).value
  end

  test "I64 signed view handles both sides of the sign bit" do
    {0 => 0, 0x7fffffffffffffff => 0x7fffffffffffffff,
     0x8000000000000000 => -9223372036854775808, 0xffffffffffffffff => -1}.each do |bits, signed|
      assert_equal signed, Wardite::I64(bits).value_s
    end
  end

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
