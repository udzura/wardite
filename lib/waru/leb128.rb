module Waru
  module Leb128Helpers
    # @rbs buf: File|IO::Buffer
    # @rbs return: Integer
    def fetch_uleb128(buf)
      dest = 0
      level = 0
      while b = buf.read(1)
        if b == nil
          raise LoadError, "buffer too short"
        end
        c = b.ord

        upper, lower = (c >> 7), (c & (1 << 7) - 1)
        dest |= lower << (7 * level)
        if upper == 0
          return dest
        end

        if level > 6
          break
        end
        level += 1
      end
      # unreachable but...
      raise "unreachable! debug: dest = #{dest} level = #{level}"
    end

    # @rbs buf: File|IO::Buffer
    # @rbs return: Integer
    def fetch_sleb128(buf)
      dest = 0
      level = 0
      while b = buf.read(1)
        if b == nil
          raise LoadError, "buffer too short"
        end
        c = b.ord

        upper, lower = (c >> 7), (c & (1 << 7) - 1)
        dest |= lower << (7 * level)
        if upper == 0
          break
        end

        if level > 6
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