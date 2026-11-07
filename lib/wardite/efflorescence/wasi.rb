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
          unless function.callsig == [:i32, :i32, :i32, :i32] && function.retsig == [:i32]
            raise Wardite::LoadError, "invalid WASI signature for fd_write"
          end
          environment.method(:fd_write_from_registers)
        when :proc_exit
          unless function.callsig == [:i32] && function.retsig.empty?
            raise Wardite::LoadError, "invalid WASI signature for proc_exit"
          end
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

      # @rbs store: Wardite::Store
      # @rbs fd: Integer
      # @rbs iovs: Integer
      # @rbs count: Integer
      # @rbs written_at: Integer
      # @rbs return: Integer
      def fd_write_i32(store, fd, iovs, count, written_at)
        file = fd_table[fd]
        return Wasi::EBADF if !file || file.is_a?(Wasi::PreopenedDir)

        data = store.memories[0]&.data
        return Wasi::EFAULT unless data && written_at + 4 <= data.bytesize && iovs + count * 8 <= data.bytesize

        if count == 1
          payload = iovec_payload(data, iovs)
          return Wasi::EFAULT unless payload
          written = file.write(payload)
        else
          # Validate every guest buffer before any write to the descriptor.
          payloads = [] #: Array[String]
          total = 0
          count.times do |index|
            payload = iovec_payload(data, iovs + index * 8)
            return Wasi::EFAULT unless payload
            total += payload.bytesize
            return Wasi::EOVERFLOW if total > 0xffffffff
            payloads << payload
          end
          written = 0
          payloads.each do |payload|
            bytes = file.write(payload)
            written += bytes
            break if bytes < payload.bytesize
          end
        end
        data[written_at, 4] = [written].pack("V")
        0
      rescue Errno::EBADF
        Wasi::EBADF
      end

      # @rbs data: String
      # @rbs iov: Integer
      # @rbs return: String?
      def iovec_payload(data, iov)
        offset = Integer(data.unpack1("V", offset: iov))
        length = Integer(data.unpack1("V", offset: iov + 4))
        return nil if offset + length > data.bytesize
        data.byteslice(offset, length)
      end
    end
  end
end
