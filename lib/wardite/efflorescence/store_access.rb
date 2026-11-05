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

      # @rbs return: Wardite::Memory
      def memory
        @store.memories[0] || raise(Wardite::EvalError, "missing memory 0")
      end
    end
  end
end
