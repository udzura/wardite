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
      dest = 0
      level = 0
      while b = buf.read(1)
        raise LoadError, "buffer too short" unless b
        c = b.ord

        upper, lower = (c >> 7), (c & (1 << 7) - 1)
        dest |= lower << (7 * level)
        if upper == 0
          break
        end

        if level > max_level
          raise "unreachable! debug: dest = #{dest} level = #{level}"
        end
        level += 1
      end
      shift = 7 * (level + 1) - 1
      return dest | -(dest & (1 << shift))   
    end

    module_function :fetch_uleb128, :fetch_sleb128
  end
end