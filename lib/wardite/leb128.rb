# rbs_inline: enabled
module Wardite
  module Leb128Helper
    # @rbs buf: File|StringIO
    # @rbs max_level: Integer
    # @rbs return: Integer
    def fetch_uleb128(buf, max_level: 8)
      dest = 0
      level = 0
      while b = buf.read(1)
        raise LoadError, "buffer too short" unless b
        c = b.ord
        return c if c < 0x80 && level.zero?

        upper, lower = (c >> 7), (c & (1 << 7) - 1)
        dest |= lower << (7 * level)
        if upper == 0
          return dest
        end

        if level > max_level
          break
        end
        level += 1
      end
      # unreachable but...
      raise "unreachable! debug: dest = #{dest} level = #{level}"
    end

    # @rbs buf: File|StringIO
    # @rbs return: Integer
    def fetch_sleb128(buf, max_level: 8)
      bytes = [] #: Array[Integer]
      negative = false
      level = 0
      while b = buf.read(1)
        raise LoadError, "buffer too short" unless b
        c = b.ord

        upper, lower = (c >> 7), (c & (1 << 7) - 1)
        bytes << lower
        negative = (c & 0x40) != 0
        if upper == 0
          break
        end

        if level > max_level
          raise "signed LEB128 exceeds maximum level #{max_level}"
        end
        level += 1
      end
      # Starting with the sign extension avoids an unsigned 70-bit
      # intermediate when decoding a ten-byte signed 64-bit integer.
      dest = negative ? -1 : 0
      bytes.reverse_each do |lower|
        dest = (dest << 7) | lower
      end
      dest
    end

    module_function :fetch_uleb128, :fetch_sleb128
  end
end
