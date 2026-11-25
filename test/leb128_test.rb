# frozen_string_literal: true

require "test_helper"
require "tempfile"

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

  test "i64 LEB128 rejects invalid sign padding, a continuation after byte ten and truncation" do
    %w[80808080808080808001 ffffffffffffffffff7e 8080808080808080808000 8080].each do |hex|
      assert_raise(Wardite::LoadError) do
        Wardite::Leb128Helper.fetch_sleb128(StringIO.new([hex].pack("H*")), width: 64)
      end
    end
  end

  test "File and StringIO agree on zero, unsigned limits and EOF" do
    cases = [
      ["00", 0, nil],
      ["ffffffff0f", 0xffffffff, nil],
      ["8080808010", nil, "unsigned LEB128 exceeds width"],
      ["8080808080", nil, "integer representation too long"],
      ["80", nil, "invalid or truncated unsigned LEB128"],
      ["", nil, "invalid or truncated unsigned LEB128"]
    ]
    cases.each do |hex, expected, error|
      bytes = [hex].pack("H*")
      Tempfile.create("leb128", binmode: true) do |file|
        file.write(bytes)
        file.rewind
        [file, StringIO.new(bytes)].each do |input|
          if error
            assert_raise_message(error) { Wardite::Leb128Helper.fetch_uleb128(input) }
          else
            assert_equal expected, Wardite::Leb128Helper.fetch_uleb128(input)
          end
        end
        assert_equal bytes.bytesize, file.pos
      end
    end
  end
end
