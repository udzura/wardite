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
        #   def self.wardite_jit_run: (String, Integer, Integer, Integer) -> Integer

        ffi_source <<~C
          #if defined(__APPLE__) && defined(__aarch64__) && !defined(__arm64e__)
          #include <sys/mman.h>
          #include <libkern/OSCacheControl.h>

          int wardite_jit_supported(void) { return 1; }

          // Keep the mapping local to this invocation. A mapping failure is
          // reported before entering guest code; all i32 results fit in long.
          long wardite_jit_run(const char *bytes, size_t size, uint32_t a, uint32_t b) {
            void *page = mmap(NULL, size, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANON, -1, 0);
            if (page == MAP_FAILED) return -1;
            memcpy(page, bytes, size);
            long result = -1;
            if (mprotect(page, size, PROT_READ | PROT_EXEC) == 0) {
              sys_icache_invalidate(page, size);
              result = ((long (*)(uint32_t, uint32_t))page)(a, b);
            }
            munmap(page, size);
            return result;
          }
          #else
          int wardite_jit_supported(void) { return 0; }
          long wardite_jit_run(const char *bytes, size_t size, uint32_t a, uint32_t b) { return -1; }
          #endif
        C
        ffi_func :wardite_jit_supported, [], :int
        ffi_func :wardite_jit_run, [:binstr, :size_t, :uint32, :uint32], :long
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

        result = Native.wardite_jit_run(code, code.bytesize, arguments.fetch(0), arguments.fetch(1, 0))
        return result if result >= 0

        if result == -2
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
