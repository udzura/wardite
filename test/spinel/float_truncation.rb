# This program must compile without --int-overflow=promote.
require "wardite/errors"
require "wardite/value"

puts Wardite::F32(9223372036854775808.0).trunc_u(to: :i64).value
puts Wardite::F32(1e30).trunc_sat_u(to: :i64).value
puts Wardite::F32(-1e30).trunc_sat_u(to: :i64).value
puts Wardite::F32(1e30).trunc_sat_u(to: :i32).value
