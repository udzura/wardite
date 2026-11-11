# frozen_string_literal: true

require "wardite"

bits = Wardite::FloatBits
alu = Wardite::Efflorescence::FloatArithmetic
[0, 0x80000000, 1, 0x00800000, 0x7f7fffff, 0x7f800000, 0xff800000].each do |raw|
  raise "binary32 round trip" unless bits.from_float(:f32, bits.to_float(:f32, raw)) == raw
end
[0, -9223372036854775807 - 1, 1, 0x0010000000000000, 0x7fefffffffffffff,
 0x7ff0000000000000, -4503599627370496].each do |raw|
  raise "binary64 round trip" unless bits.from_float(:f64, bits.to_float(:f64, raw)) == raw
end
[0x7f800123, 0xffc00123].each do |raw|
  raise "binary32 NaN bytes" unless bits.read(:f32, bits.write(:f32, raw)) == raw
end
[0x7ff0000000000123, -2251799813684957].each do |raw|
  raise "binary64 NaN bytes" unless bits.read(:f64, bits.write(:f64, raw)) == raw
end

# Test ties on both sides of the normal/subnormal boundary and the midpoint
# between zero and the least subnormal. Inputs and expectations are bits.
[
  [0x00800001, 0x40000000, 0x00400000],
  [0x00800003, 0x40000000, 0x00400002],
  [0x00ffffff, 0x40000000, 0x00800000],
  [1, 0x40000000, 0],
  [1, 0x3fffffff, 1],
  [1, 0x40000001, 0],
  [0x3f800000, 0x80000000, 0xff800000],
].each do |left, right, expected|
  value = alu.divide(bits.to_float(:f32, left), bits.to_float(:f32, right))
  raise "binary32 division" unless bits.from_float(:f32, value) == expected
end
[
  [0x3f800001, 0x3f800000],
  [0x3f800002, 0x3f800001],
  [0x80000000, 0x80000000],
].each do |raw, expected|
  raise "binary32 sqrt" unless bits.from_float(:f32, alu.sqrt(bits.to_float(:f32, raw))) == expected
end
raise "binary64 sqrt" unless bits.from_float(:f64, alu.sqrt(2.0)) == 0x3ff6a09e667f3bcd
raise "binary64 division" unless bits.from_float(:f64, alu.divide(1.0, 3.0)) == 0x3fd5555555555555
raise "binary64 subnormal" unless bits.from_float(:f64, alu.divide(bits.to_float(:f64, 3), 2.0)) == 2
raise "zero divided by zero" unless alu.divide(0.0, 0.0).nan?
raise "sqrt negative" unless alu.sqrt(-1.0).nan?
puts "M5 float bit and rounding probes passed"
