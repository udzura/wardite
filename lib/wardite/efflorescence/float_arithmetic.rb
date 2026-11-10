# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    module FloatArithmetic
      # A normalized quotient of binary32 inputs is A/B scaled by a power of
      # two. B < 2**24. Its distance from a binary32 midpoint, unless equal,
      # exceeds 2**-48 in the quotient's binade scaled to [1, 2).
      # @rbs left: Float
      # @rbs right: Float
      # @rbs return: Float
      def self.divide(left, right)
        left / right
      end

      # Squaring a binary32 midpoint gives a dyadic with at most 48 fractional
      # bits in that binade's scale. A distinct binary32 radicand differs by at
      # least 2**-48, so its square root differs by more than 2**-50.
      # @rbs value: Float
      # @rbs return: Float
      def self.sqrt(value)
        return value if value == 0.0
        value < 0.0 ? Float::NAN : Math.sqrt(value)
      end
    end
  end
end
