# This program must compile without --int-overflow=promote.
require "wardite/value"

puts Wardite::I64(0x7fffffffffffffff).value
puts Wardite::I64(0x8000000000000000).value
puts Wardite::I64(0xffffffffffffffff).value
puts Wardite::I64(-1).value
puts Wardite::I64(0x100000000000000000000002a).value
puts Wardite::I64(-0x1000000000000000000000001).value
