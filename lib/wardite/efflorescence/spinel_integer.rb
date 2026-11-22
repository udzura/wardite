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
      #   def self.wardite_byte_lookup: (IO::Buffer, Integer, Integer, Integer) -> Integer

      ffi_source <<~C
        #include <stdint.h>

        int64_t wardite_i64_shl(int64_t bits, int64_t count) {
          return (int64_t)((uint64_t)bits << ((uint64_t)count & 63));
        }

        int64_t wardite_i64_shr_u(int64_t bits, int64_t count) {
          return (int64_t)((uint64_t)bits >> ((uint64_t)count & 63));
        }

        // The borrowed view is valid only within this call. The table address
        // wraps in memory32; each byte load can trap separately.
        int wardite_byte_lookup(void *memory, size_t size, uint32_t address, uint32_t table) {
          const uint8_t *bytes = (const uint8_t *)memory;
          if (address >= size) return -1;
          uint32_t byte = bytes[address];
          uint32_t index = table + byte;
          if (index >= size) return -1;
          return (int)((byte << 8) | bytes[index]);
        }
      C
      ffi_func :wardite_i64_shl, [:int64, :int64], :int64
      ffi_func :wardite_i64_shr_u, [:int64, :int64], :int64
      ffi_func :wardite_byte_lookup, [:buffer_in, :size_t, :uint32, :uint32], :int
    end
  end
end
