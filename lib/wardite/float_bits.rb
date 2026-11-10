# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module FloatBits
    # @rbs type: Symbol
    # @rbs return: bool
    def self.float_type?(type)
      type == :f32 || type == :f64
    end

    # f32 carriers are unsigned, f64 carriers are signed.
    # @rbs type: Symbol
    # @rbs bytes: String
    # @rbs return: Integer
    def self.read(type, bytes)
      bits = type == :f32 ? bytes.unpack1("V") : bytes.unpack1("q<")
      raise LoadError, "invalid float bytes" unless bits.is_a?(Integer)
      bits
    end

    # @rbs type: Symbol
    # @rbs bits: Integer
    # @rbs return: String
    def self.write(type, bits)
      type == :f32 ? [bits].pack("V") : [bits].pack("q<")
    end

    # @rbs type: Symbol
    # @rbs bits: Integer
    # @rbs return: Float
    def self.to_float(type, bits)
      bytes = write(type, bits)
      value = type == :f32 ? bytes.unpack1("e") : bytes.unpack1("E")
      raise EvalError, "invalid float carrier" unless value.is_a?(Float)
      value
    end

    # @rbs type: Symbol
    # @rbs value: Float
    # @rbs return: Integer
    def self.from_float(type, value)
      read(type, type == :f32 ? [value].pack("e") : [value].pack("E"))
    end
  end
end
