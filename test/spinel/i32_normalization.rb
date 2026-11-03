# This program must compile without --int-overflow=promote.
require "wardite/value"

puts Wardite::I32(0x1000000000000000000000002a).value
puts Wardite::I32(-0x10000000000000000000000001).value
