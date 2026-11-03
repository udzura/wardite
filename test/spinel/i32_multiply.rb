# These products must not require --int-overflow=promote.
require "wardite/value"

puts Wardite::I32(0xffffffff).multiply(Wardite::I32(0xffffffff)).value
puts Wardite::I32(0x80000000).multiply(Wardite::I32(2)).value
puts Wardite::I32(0x10001).multiply(Wardite::I32(0x10001)).value
