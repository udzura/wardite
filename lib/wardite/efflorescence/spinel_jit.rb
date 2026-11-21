# frozen_string_literal: true
# rbs_inline: enabled

require_relative "spinel_jit/aarch64"

module Wardite
  module Efflorescence
    class SpinelJIT
      module Native
        # @rbs!
        #   def self.ffi_source: (String) -> void
        #   def self.ffi_func: (Symbol, Array[Symbol], Symbol) -> void
        #   def self.wardite_jit_supported: () -> Integer
        #   def self.wardite_jit_run: (String, Integer, IO::Buffer) -> Integer

        ffi_source <<~C
          enum { WARDITE_JIT_MAPPING_FAILED = 2 };
          #if defined(__APPLE__) && defined(__aarch64__) && !defined(__arm64e__)
          #include <sys/mman.h>
          #include <libkern/OSCacheControl.h>

          int wardite_jit_supported(void) { return 1; }

          // On success the generated function replaces slot zero with its result.
          int wardite_jit_run(const char *bytes, size_t size, void *slots) {
            void *page = mmap(NULL, size, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANON, -1, 0);
            if (page == MAP_FAILED) return WARDITE_JIT_MAPPING_FAILED;
            memcpy(page, bytes, size);
            int status = WARDITE_JIT_MAPPING_FAILED;
            if (mprotect(page, size, PROT_READ | PROT_EXEC) == 0) {
              sys_icache_invalidate(page, size);
              status = ((int (*)(uint64_t *))page)(slots);
            }
            munmap(page, size);
            return status;
          }
          #else
          int wardite_jit_supported(void) { return 0; }
          int wardite_jit_run(const char *bytes, size_t size, void *slots) { return WARDITE_JIT_MAPPING_FAILED; }
          #endif
        C
        ffi_func :wardite_jit_supported, [], :int
        ffi_func :wardite_jit_run, [:binstr, :size_t, :buffer_inout], :int
      end

      def initialize
        @entries = {} #: Hash[Integer, String?]
      end

      # nil is cached for unsupported functions, just like a successful entry.
      # @rbs function: Function
      # @rbs arguments: Array[Integer]
      # @rbs return: Integer?
      def call(function, arguments)
        index = function.index
        unless @entries.key?(index)
          @entries[index] = AArch64.new.compile(function)
          if ENV["WARDITE_TRACE"]
            warn "MIR JIT function #{index}: #{@entries[index] ? 'compiled' : 'interpreter'}"
          end
        end
        code = @entries[index]
        return unless code

        slots = IO::Buffer.new([arguments.size, 1].max * 8)
        arguments.each_with_index { |value, i| slots.set_value(:s64, i * 8, value) }
        status = Native.wardite_jit_run(code, code.bytesize, slots)
        return Integer(slots.get_value(:s64, 0)) if status == AArch64::OK

        if status == AArch64::FALLBACK
          # Only side-effect-free instructions ran; replay from the original arguments.
          warn "MIR JIT function #{index}: interpreter bailout" if ENV["WARDITE_TRACE"]
          return nil
        end

        @entries[index] = nil
        warn "MIR JIT function #{index}: executable mapping unavailable" if ENV["WARDITE_TRACE"]
        nil
      end
    end
  end
end
