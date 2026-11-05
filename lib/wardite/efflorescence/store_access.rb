# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    # Checked byte operations live off the integer dispatch path. Store remains
    # the owner of all state; never retain a Memory#data buffer across a call.
    class StoreAccess
      PAGE_SIZE = 65536
      MAX_PAGES = 65536

      # @rbs start: Integer
      # @rbs length: Integer
      # @rbs size: Integer
      # @rbs return: void
      def self.check_range(start, length, size)
        unless start >= 0 && length >= 0 && start <= size && length <= size - start
          raise Wardite::EvalError, "out of bounds memory access"
        end
      end

      # @rbs store: Wardite::Store
      def initialize(store)
        @store = store
      end

      # @rbs index: Integer
      # @rbs return: Wardite::Global
      def global_at(index)
        @store.globals[index] || raise(Wardite::EvalError, "invalid global index")
      end

      # @rbs index: Integer
      # @rbs return: Integer
      def global_get(index)
        value = global_at(index).value
        raise Wardite::EvalError, "invalid i32 global value" unless value.is_a?(Wardite::I32)
        value.value & 0xffffffff
      end

      # Boxing is confined to the shared Store boundary. Existing register
      # snapshots contain independent integers, never a mutable Global object.
      # @rbs index: Integer
      # @rbs value: Integer
      # @rbs return: void
      def global_set(index, value)
        global_at(index).value = Wardite::I32.new(value)
      end

      # @rbs address: Integer
      # @rbs offset: Integer
      # @rbs width: Integer
      # @rbs signed: bool
      # @rbs return: Integer
      def load(address, offset, width, signed)
        data = memory.data
        start = address + offset
        StoreAccess.check_range(start, width, data.bytesize)
        value = 0
        byte = 0
        while byte < width
          part = data.getbyte(start + byte) || raise(Wardite::EvalError, "missing checked memory byte")
          value |= part << (byte * 8)
          byte += 1
        end
        if signed && value >= (1 << (width * 8 - 1))
          value -= 1 << (width * 8)
        end
        value & 0xffffffff
      end

      # Check the whole access before the first write. Effective addresses are
      # wide integers; the static offset never wraps back into memory32.
      # @rbs address: Integer
      # @rbs offset: Integer
      # @rbs width: Integer
      # @rbs value: Integer
      # @rbs return: void
      def store(address, offset, width, value)
        data = memory.data
        start = address + offset
        StoreAccess.check_range(start, width, data.bytesize)
        byte = 0
        while byte < width
          data.setbyte(start + byte, (value >> (byte * 8)) & 255)
          byte += 1
        end
      end

      # @rbs return: Integer
      def size
        memory.current
      end

      # Only the buffer preparation boundary handles allocation failure. Ruby
      # implementation errors and traps must propagate rather than look like a
      # successful Wasm instruction returning -1.
      # @rbs delta: Integer
      # @rbs return: Integer
      def grow(delta)
        target = memory
        previous = target.current
        declared = target.max
        limit = declared && declared < MAX_PAGES ? declared : MAX_PAGES
        return 0xffffffff if delta < 0 || previous > limit || delta > limit - previous
        return previous if delta == 0
        begin
          data = grown_buffer(target, delta)
        rescue NoMemoryError
          return 0xffffffff
        end
        target.data = data
        target.current = previous + delta
        previous
      end

      # Kept separate so tests can inject allocation failure without requesting
      # gigabytes or depending on the process's available resources.
      # @rbs target: Wardite::Memory
      # @rbs delta: Integer
      # @rbs return: String
      def grown_buffer(target, delta)
        target.data + ("\0".b * (delta * PAGE_SIZE))
      end

      # @rbs return: Wardite::Memory
      def memory
        @store.memories[0] || raise(Wardite::EvalError, "missing memory 0")
      end
    end
  end
end
