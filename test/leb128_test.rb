# frozen_string_literal: true

require "test_helper"

class WarditeLeb128Test < Test::Unit::TestCase
  test "signed LEB128 decodes 64-bit boundaries and extended encodings" do
    {
      "00" => 0, "7f" => -1, "3f" => 63, "c000" => 64,
      "40" => -64, "bf7f" => -65,
      "ffffffffffffffffff00" => 9223372036854775807,
      "8080808080808080807f" => -9223372036854775808,
      "ffffffffffffffffff7f" => -1,
      "80808080808080808000" => 0
    }.each do |hex, expected|
      buffer = StringIO.new([hex].pack("H*"))
      assert_equal expected, Wardite::Leb128Helper.fetch_sleb128(buffer, max_level: 16)
      assert_equal hex.length / 2, buffer.pos
    end
  end
end
