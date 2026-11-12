# frozen_string_literal: true

require_relative "efflorescence/i64_arithmetic"
require_relative "efflorescence/float_arithmetic"
require_relative "efflorescence/ir"
require_relative "efflorescence/store_access"
require_relative "efflorescence/translator"
require_relative "efflorescence/optimizer"
require_relative "efflorescence/register_validation"
require_relative "efflorescence/inspection"
require_relative "efflorescence/vm"

# Spinel initializes the cache tables at startup, after Opcode is defined.
if RUBY_ENGINE == "spinel"
  require_relative "efflorescence/mir_cache"
  require_relative "efflorescence/snapshot"
end
