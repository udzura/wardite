# frozen_string_literal: true
# rbs_inline: enabled
module Wardite
  # basic error class.
  class WebAssemblyError < StandardError    
  end

  class UncaughtWasmException < WebAssemblyError
    attr_reader :exception_value #: Wardite::Efflorescence::ExceptionValue
    attr_reader :tag #: Wardite::Efflorescence::Tag
    # Public payloads follow tag order, with floats decoded at the boundary.
    attr_reader :payload #: Array[Integer | Float | FunctionReference | nil]

    # @rbs value: Wardite::Efflorescence::ExceptionValue
    def initialize(value)
      @exception_value = value
      @tag = value.tag
      @payload = [] #: Array[Integer | Float | FunctionReference | nil]
      @tag.parameter_types.each_with_index do |type, i|
        bits = value.payload_bits.fetch(i)
        @payload << if Efflorescence::FunctionEntry.function_ref?(type)
          value.references.fetch(i, nil)
        else
          FloatBits.float_type?(type) ? FloatBits.to_float(type, bits) : bits
        end
      end
      @payload.freeze
      super("uncaught Wasm exception: #{@payload.inspect}")
    end
  end

  class LinkedWasmException < UncaughtWasmException; end

  class StackExhausted < WebAssemblyError; end

  class IntegerOverflow < WebAssemblyError; end
end