# rbs_inline: enabled
module Wardite
  module Leb128Helper
    # @rbs buf: File|StringIO
    # @rbs max_level: Integer
    # @rbs return: Integer
    def fetch_uleb128(buf, max_level: 4)
      dest = 0
      level = 0
      while b = buf.read(1)
        raise LoadError, "buffer too short" unless b
        c = b.ord
        return c if c < 0x80 && level.zero?

        upper, lower = (c >> 7), (c & (1 << 7) - 1)
        dest |= lower << (7 * level)
        if level >= max_level && (upper != 0 || (max_level == 4 && c > 15))
          raise LoadError, "unsigned LEB128 exceeds width"
        end
        if upper == 0
          return dest
        end

        if level > max_level
          break
        end
        level += 1
      end
      raise LoadError, "invalid or truncated unsigned LEB128"
    end

    # @rbs buf: File|StringIO
    # @rbs return: Integer
    # @rbs max_level: Integer
    # @rbs width: Integer?
    def fetch_sleb128(buf, max_level: 8, width: nil)
      max_level = (width - 1) / 7 if width
      bytes = [] #: Array[Integer]
      negative = false
      level = 0
      terminated = false
      while b = buf.read(1)
        c = b.ord

        upper, lower = (c >> 7), (c & (1 << 7) - 1)
        bytes << lower
        negative = (c & 0x40) != 0
        if upper == 0
          if width && level == max_level
            used = width - 7 * level
            padding = lower >> (used - 1)
            unless padding == 0 || padding == (1 << (8 - used)) - 1
              raise LoadError, "signed LEB128 exceeds width"
            end
          end
          terminated = true
          break
        end

        if level >= max_level
          raise LoadError, "signed LEB128 exceeds maximum level #{max_level}"
        end
        level += 1
      end
      raise LoadError, "truncated signed LEB128" unless terminated
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
