# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    module SpinelInteger
      # @rbs!
      #   def self.ffi_source: (String) -> void
      #   def self.ffi_func: (Symbol, Array[Symbol], Symbol) -> void
      #   def self.wardite_i64_shl: (Integer, Integer) -> Integer
      #   def self.wardite_i64_shr_u: (Integer, Integer) -> Integer

      ffi_source <<~C
        #include <stdint.h>

        int64_t wardite_i64_shl(int64_t bits, int64_t count) {
          return (int64_t)((uint64_t)bits << ((uint64_t)count & 63));
        }

        int64_t wardite_i64_shr_u(int64_t bits, int64_t count) {
          return (int64_t)((uint64_t)bits >> ((uint64_t)count & 63));
        }
      C
      ffi_func :wardite_i64_shl, [:int64, :int64], :int64
      ffi_func :wardite_i64_shr_u, [:int64, :int64], :int64
    end
  end
end
