# frozen_string_literal: true
# rbs_inline: enabled

require_relative "spinel_jit/aarch64"
require_relative "spinel_jit/byte_loop"

module Wardite
  module Efflorescence
    class SpinelJIT
      # Private dispatch label, present only in a VM-local copy of verified MIR.
      LOOP_BACKEDGE = -1

      class LoopBody
        attr_reader :instructions #: Array[Integer]

        # @rbs function: Function
        def initialize(function)
          @instructions = function.bytecode.dup
        end
      end

      module Native
        # @rbs!
        #   def self.ffi_source: (String) -> void
        #   def self.ffi_func: (Symbol, Array[Symbol], Symbol) -> void
        #   def self.wardite_jit_supported: () -> Integer
        #   def self.wardite_jit_run: (String, Integer, IO::Buffer) -> Integer
        #   def self.wardite_jit_run_loop: (String, Integer, IO::Buffer, IO::Buffer, Integer) -> Integer

        ffi_source <<~C
          enum { WARDITE_JIT_MAPPING_FAILED = 2 };
          #if defined(__APPLE__) && defined(__aarch64__) && !defined(__arm64e__)
          #include <sys/mman.h>
          #include <libkern/OSCacheControl.h>

          int wardite_jit_supported(void) { return 1; }

          static void *wardite_jit_map(const char *bytes, size_t size) {
            void *page = mmap(NULL, size, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANON, -1, 0);
            if (page == MAP_FAILED) return NULL;
            memcpy(page, bytes, size);
            if (mprotect(page, size, PROT_READ | PROT_EXEC) != 0) {
              munmap(page, size);
              return NULL;
            }
            sys_icache_invalidate(page, size);
            return page;
          }

          // On success the generated function replaces slot zero with its result.
          int wardite_jit_run(const char *bytes, size_t size, void *slots) {
            void *page = wardite_jit_map(bytes, size);
            if (!page) return WARDITE_JIT_MAPPING_FAILED;
            int status = ((int (*)(uint64_t *))page)(slots);
            munmap(page, size);
            return status;
          }

          // A loop returns the original flat MIR word PC at which the VM resumes.
          int wardite_jit_run_loop(const char *bytes, size_t size, void *slots, const void *memory, size_t length) {
            void *page = wardite_jit_map(bytes, size);
            if (!page) return -1;
            int pc = ((int (*)(uint64_t *, const void *, size_t))page)(slots, memory, length);
            munmap(page, size);
            return pc;
          }
          #else
          int wardite_jit_supported(void) { return 0; }
          int wardite_jit_run(const char *bytes, size_t size, void *slots) { return WARDITE_JIT_MAPPING_FAILED; }
          int wardite_jit_run_loop(const char *bytes, size_t size, void *slots, const void *memory, size_t length) { return -1; }
          #endif
        C
        ffi_func :wardite_jit_supported, [], :int
        ffi_func :wardite_jit_run, [:binstr, :size_t, :buffer_inout], :int
        ffi_func :wardite_jit_run_loop, [:binstr, :size_t, :buffer_inout, :buffer_in, :size_t], :int
      end

      def initialize
        @entries = {} #: Hash[Integer, String?]
        @loop_bodies = {} #: Hash[Integer, LoopBody?]
        @loops = [] #: Array[String]
      end

      # The first iteration runs in the VM. Replace only a taken backward
      # BR_IF so incoming branches and snapshots keep their original word PCs.
      # @rbs function: Function
      # @rbs return: LoopBody?
      def loop_body(function)
        original = function.bytecode
        return unless function.uses_store && function.register_count <= AArch64::MAX_SLOTS
        return @loop_bodies[function.index] if @loop_bodies.key?(function.index)

        body = nil #: LoopBody?
        width = Lowerer::WIDTH
        pc = 0
        while pc < original.size
          if original.fetch(pc) == Opcode::BR_IF
            head = original.fetch(pc + 2)
            if head < pc && pc - head <= 64 * width
              code = AArch64.new.compile_byte_loop(function, head, pc)
              if code
                selected = body || LoopBody.new(function)
                selected.instructions[pc] = LOOP_BACKEDGE
                selected.instructions[pc + 3] = @loops.size
                body = selected
                @loops << code
              end
            end
          end
          pc += width
        end
        @loop_bodies[function.index] = body
        body
      end

      # @rbs frame: Frame
      # @rbs pc: Integer
      # @rbs memory: IO::Buffer
      # @rbs return: Integer
      def run_loop(frame, pc, memory)
        instructions = frame.instructions
        code = @loops.fetch(instructions.fetch(pc + 3))
        registers = frame.registers
        slots = IO::Buffer.new(registers.size * 8)
        registers.each_with_index { |value, i| slots.set_value(:s64, i * 8, value) }
        resume = Native.wardite_jit_run_loop(code, code.bytesize, slots, memory, memory.size)
        if resume < 0
          instructions[pc] = Opcode::BR_IF
          return instructions.fetch(pc + 2)
        end
        registers.size.times { |i| registers[i] = Integer(slots.get_value(:s64, i * 8)) }
        if ENV["WARDITE_TRACE"]
          warn "MIR JIT byte loop function #{frame.function.index}: backedge #{pc / Lowerer::WIDTH}, native exit #{resume / Lowerer::WIDTH}"
        end
        resume
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
