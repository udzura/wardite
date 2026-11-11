# frozen_string_literal: true
# rbs_inline: enabled

require "wardite/wasi"

module Wardite
  module Efflorescence
    class WasiSnapshotPreview1 < Wardite::WasiSnapshotPreview1
      FD_WRITE_ARGUMENTS = [0, 1, 2, 3].freeze
      PROC_EXIT_ARGUMENTS = [0].freeze

      # @rbs fnname: Symbol
      # @rbs return: Wardite::_WasmCallable
      def callable(fnname)
        public_method(fnname)
      end

      # @rbs environment: Wardite::Efflorescence::WasiSnapshotPreview1
      # @rbs function: Wardite::ExternalFunction
      # @rbs return: Wardite::Efflorescence::_WasiCallable?
      def self.unboxed_callable(environment, function)
        case function.name
        when :fd_write
          environment.method(:fd_write_from_registers)
        when :proc_exit
          environment.method(:proc_exit_from_registers)
        end
      end

      private

      # @rbs store: Wardite::Store
      # @rbs values: Array[Integer]
      # @rbs sources: Array[Integer]?
      # @rbs return: Integer
      def fd_write_from_registers(store, values, sources)
        indices = sources || FD_WRITE_ARGUMENTS
        fd_write_i32(store, values.fetch(indices.fetch(0)), values.fetch(indices.fetch(1)),
          values.fetch(indices.fetch(2)), values.fetch(indices.fetch(3)))
      end

      # @rbs _store: Wardite::Store
      # @rbs values: Array[Integer]
      # @rbs sources: Array[Integer]?
      # @rbs return: bot
      def proc_exit_from_registers(_store, values, sources)
        exit(values.fetch((sources || PROC_EXIT_ARGUMENTS).fetch(0)))
      end

    end
  end
end
