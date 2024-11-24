# frozen_string_literal: true
# rbs_inline: enabled
module Wardite
  # basic error class.
  class WebAssemblyError < StandardError    
  end

  class IntegerOverflow < WebAssemblyError; end
end