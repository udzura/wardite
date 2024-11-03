# rbs_inline: enabled

module Wardite
  class I32
    I32_MAX = (1<<32) - 1
    # value should be stored as unsigned in I32/I64
    # when we want to access signed value, it's done via #value_s
    attr_accessor :value #: Integer

    # returns a value interpreted as signed integer
    # @rbs return: Integer
    def value_s
      (@value >> 31).zero? ?
        @value :
        (@value ^ I32_MAX) + 1
    end

    # TODO: eliminate use of pack, to support mruby - in this file!
    # @rbs return: String
    def packed
      [self.value].pack("I")
    end

    def inspect
      "I32(#{@value})"
    end
  end

  class I64
    I64_MAX = (1<<64) - 1

    attr_accessor :value #: Integer

    # returns a value interpreted as signed integer
    # @rbs return: Integer
    def value_s
      (@value >> 63).zero? ?
        @value :
        (@value ^ I64_MAX) + 1
    end

    # @rbs return: String
    def packed
      [self.value].pack("L")
    end

    def inspect
      "I64(#{@value})"
    end
  end

  class F32
    attr_accessor :value #: Float    

    # @rbs return: String
    def packed
      [self.value].pack("f")
    end

    def inspect
      "F32(#{@value})"
    end
  end

  class F64
    attr_accessor :value #: Float    

    # @rbs return: String
    def packed
      [self.value].pack("d")
    end

    def inspect
      "F64(#{@value})"
    end
  end

  module ValueHelper
    # @rbs value: Integer
    # @rbs return: I32
    def I32(value)
      I32.new.tap{|i| i.value = value }
    end

    # @rbs value: Integer
    # @rbs return: I64
    def I64(value)
      I64.new.tap{|i| i.value = value }
    end

    # @rbs value: Float
    # @rbs return: F32
    def F32(value)
      F32.new.tap{|i| i.value = value }
    end

    # @rbs value: Float
    # @rbs return: F64
    def F64(value)
      F64.new.tap{|i| i.value = value }
    end
  end
end