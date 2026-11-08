# frozen_string_literal: true

require "wardite"
require "wardite/efflorescence"

arithmetic = Wardite::Efflorescence::I64Arithmetic
function = Wardite::Efflorescence::Function.new(0, [], [], 0)
function.allocate_constant(1)
function.allocate_constant(1, type: :i64)
raise "constant type mismatch" unless function.register_types == [:i32, :i64]
[
  ["00", 0],
  ["01", 1],
  ["7f", -1],
  ["8080808010", 0x100000000],
  ["ffffffffffffffffff00", 9223372036854775807],
  ["8080808080808080807f", -9223372036854775807 - 1]
].each do |hex, expected|
  value = Wardite::Leb128Helper.fetch_sleb128(StringIO.new([hex].pack("H*")), width: 64)
  raise "decode mismatch" unless value == expected
  register = function.allocate_constant(arithmetic.join(arithmetic.low(value), arithmetic.high(value)), type: :i64)
  frame = Wardite::Efflorescence::Frame.new(function.copy, -1)
  raise "frame mismatch" unless frame.registers.fetch(register) == expected
  raise "box mismatch" unless Wardite::I64(value).value_s == expected
end
puts "M4 signed registers passed"
