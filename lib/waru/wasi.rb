# rbs_inline: enabled
module Waru
  class WasiSnapshotPreview1
    attr_accessor :fd_table #: Array[IO]

    def initialize
      @fd_table = [
        STDIN,
        STDOUT,
        STDERR,
      ]
    end

    # @rbs store: Store
    # @rbs args: Array[Object]
    # @rbs return: Object
    def fd_write(store, args)
      iargs = args.map do |elm|
        if elm.is_a?(Integer)
          elm
        else
          raise Waru::ArgumentError, "invalid type of args: #{args.inspect}"
        end
      end #: Array[Integer]
      fd, iovs, iovs_len, rp = *iargs
      if !fd || !iovs || !iovs_len || !rp
        raise Waru::ArgumentError, "args too short"
      end
      file = self.fd_table[fd]
      memory = store.memories[0]
      nwritten = 0
      iovs_len.times do
        start = unpack_le_int(memory.data[iovs...(iovs+4)])
        iovs += 4
        slen = unpack_le_int(memory.data[iovs...(iovs+4)])
        iovs += 4
        nwritten += file.write(memory.data[start...(start+slen)])
      end

      memory.data[rp...(rp+4)] = [nwritten].pack("I")

      0
    end


    # @rbs return: Hash[Symbol, Proc]
    def to_module
      {
        fd_write: lambda{|store, args| self.fd_write(store, args) },
      }
    end

    private
    # @rbs buf: String|nil
    # @rbs retrun: Integer
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