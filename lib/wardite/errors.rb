# frozen_string_literal: true
# rbs_inline: enabled
module Wardite
  # basic error class.
  class WebAssemblyError < StandardError    
  end

  class UncaughtWasmException < WebAssemblyError
    attr_reader :exception_value #: Wardite::Efflorescence::ExceptionValue
    attr_reader :tag #: Wardite::Efflorescence::Tag
    attr_reader :payload #: Array[Integer]

    # @rbs value: Wardite::Efflorescence::ExceptionValue
    def initialize(value)
      @exception_value = value
      @tag = value.tag
      @payload = value.payload
      super("uncaught Wasm exception: #{@payload.inspect}")
    end
  end

  class IntegerOverflow < WebAssemblyError; end
end