# This program must compile without --int-overflow=promote.
require "stringio"
require "wardite/leb128"

["ffffffffffffffffff00", "8080808080808080807f", "ffffffffffffffffff7f"].each do |hex|
  buffer = StringIO.new([hex].pack("H*"))
  puts Wardite::Leb128Helper.fetch_sleb128(buffer, max_level: 16)
end
