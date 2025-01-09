# rbs_inline: enabled

require "wardite/wasm_module"
require "wardite/wasi/errno"
require "securerandom"

module Wardite
  class WasiSnapshotPreview1
    include ValueHelper
    include WasmModule

    attr_accessor :fd_table #: Array[(IO|File)]

    def initialize
      @fd_table = [
        STDIN,
        STDOUT,
        STDERR,
      ]
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def environ_sizes_get(store, args)
      envc_p = args[0].value
      envlen_p = args[1].value
      envc = ENV.length
      envlen = ENV.map{|k,v| k.size + v.size + 1}.sum

      memory = store.memories[0]
      memory.data[envc_p...(envc_p+4)] = [envc].pack("I!")
      memory.data[envlen_p...(envlen_p+4)] = [envlen].pack("I!")
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def environ_get(store, args)
      environ_offsets_p = args[0].value
      environ_data_buf_p = args[1].value
      if !environ_data_buf_p.is_a?(Integer)
        raise ArgumentError, "invalid type of args: #{args.inspect}"
      end

      environ_offsets = [] #: Array[Integer]
      environ_data_slice = [] #: Array[String]
      current_offset = environ_data_buf_p
      ENV.each do |k, v|
        environ_offsets << current_offset
        environ_data_slice << "#{k}=#{v}"
        current_offset += "#{k}=#{v}".size + 1
      end
      environ_data = environ_data_slice.join("\0") + "\0"

      memory = store.memories[0]
      memory.data[environ_data_buf_p...(environ_data_buf_p + environ_data.size)] = environ_data

      environ_offsets.each_with_index do |offset, i|
        data_begin = environ_offsets_p + i * 4
        memory.data[data_begin...(data_begin + 4)] = [offset].pack("I!")
      end

      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def clock_time_get(store, args)
      clock_id = args[0].value
      # we dont use precision...
      _precision = args[1].value
      timebuf64 = args[2].value
      if clock_id != 0 # - CLOCKID_REALTIME
        # raise NotImplementedError, "CLOCKID_REALTIME is an only supported id"
        return -255
      end
      # timestamp in nanoseconds
      now = Time.now.to_i * 1_000_000

      memory = store.memories[0]
      now_packed = [now].pack("Q!")
      memory.data[timebuf64...(timebuf64+8)] = now_packed
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def fd_prestat_get(store, args)
      fd = args[0].value.to_i
      prestat_offset = args[1].value.to_i
      if fd >= @fd_table.size
        return Wasi::EBADF
      end
      file = @fd_table[fd]
      if !file.is_a?(File)
        return Wasi::EBADF
      end
      name = file.path
      memory = store.memories[0]
      # Zero-value 8-bit tag, and 3-byte zero-value padding
      memory.data[prestat_offset...(prestat_offset+4)] = [0].pack("I!")
      memory.data[(prestat_offset+4)...(prestat_offset+8)] = [name.size].pack("I!")
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def fd_write(store, args)
      iargs = args.map do |elm|
        if elm.is_a?(I32)
          elm.value
        else
          raise Wardite::ArgumentError, "invalid type of args: #{args.inspect}"
        end
      end #: Array[Integer]
      fd, iovs, iovs_len, rp = *iargs
      if !fd || !iovs || !iovs_len || !rp
        raise Wardite::ArgumentError, "args too short"
      end
      file = self.fd_table[fd]
      memory = store.memories[0]
      nwritten = 0
      iovs_len.times do
        start = unpack_le_int(memory.data[iovs...(iovs+4)])
        iovs += 4
        slen = unpack_le_int(memory.data[iovs...(iovs+4)])
        iovs += 4
        # TODO: parallel write?
        nwritten += file.write(memory.data[start...(start+slen)])
      end

      memory.data[rp...(rp+4)] = [nwritten].pack("I!")

      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def proc_exit(store, args)
      exit_code = args[0].value
      exit(exit_code)
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def random_get(store, args)
      buf = args[0].value.to_i
      buflen = args[1].value.to_i
      randoms = SecureRandom.random_bytes(buflen) #: String
      memory = store.memories[0]
      memory.data[buf...(buf+buflen)] = randoms
      0
    end

    private
    # @rbs buf: String|nil
    # @rbs return: Integer
    def unpack_le_int(buf)
      if !buf
        raise "empty buffer"
      end
      ret = buf.unpack1("I")
      if !ret.is_a?(Integer)
        raise "[BUG] invalid pack format"
      end
      ret
    end
  end
end