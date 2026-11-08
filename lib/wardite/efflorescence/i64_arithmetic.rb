# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    module I64Arithmetic
      MASK = 0xffffffff
      MIN = -9223372036854775807 - 1 #: Integer

      # @rbs value: Integer
      # @rbs return: Integer
      def self.low(value)
        value & MASK
      end

      # @rbs value: Integer
      # @rbs return: Integer
      def self.high(value)
        (value >> 32) & MASK
      end

      # @rbs low: Integer
      # @rbs high: Integer
      # @rbs return: Integer
      def self.join(low, high)
        low | ((high & 0x7fffffff) << 32) | ((high >> 31) * MIN)
      end

      # @rbs value: Integer
      # @rbs return: Integer
      def self.normalize(value)
        join(low(value), high(value))
      end
    end
  end
end
