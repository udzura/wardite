# rbs_inline: enabled

module Wardite
  module ValueHelper
    # @rbs value: Integer
    # @rbs return: I32
    def I32(value)
      if value < 0
        $stderr.puts "debug: negative i32 value #{value} is passed, convert to unsigned"
        value = as_u32(value)
      end
      I32.new.tap{|i| i.value = value & I32::I32_MAX }
    end

    # @rbs value: Integer
    # @rbs return: I64
    def I64(value)
      if value < 0
        $stderr.puts "debug: negative i64 value #{value} is passed, convert to unsigned"
        value = as_u64(value)
      end
      I64.new.tap{|i| i.value = value & I64::I64_MAX }
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

    private
    # @rbs value: Integer
    # @rbs return: Integer
    def as_u32(value)
      ((-value) ^ I32::I32_MAX) + 1
    end

    # @rbs value: Integer
    # @rbs return: Integer
    def as_u64(value)
      ((-value) ^ I64::I64_MAX) + 1
    end
  end

  class I32
    include ValueHelper

    I32_MAX = (1<<32) - 1
    # value should be stored as unsigned Integer, even in I32/I64
    # when we want to access signed value, it'd be done via #value_s
    attr_accessor :value #: Integer

    # returns a value interpreted as signed integer
    # @rbs return: Integer
    def value_s
      (@value >> 31).zero? ?
        @value :
        ((-@value) ^ I32_MAX) + 1
    end

    # TODO: eliminate use of pack, to support mruby - in this file!
    # @rbs return: String
    def packed
      [self.value].pack("I")
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def wrap(to:)
      I32(-1)
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def extend_(to:)
      raise EvalError, "unsupported operation"      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def trunc_s(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def trunc_u(to:)
      raise EvalError, "unsupported operation"      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def convert(to:)
      raise EvalError, "unsupported operation"
      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def demote(to:)
      raise EvalError, "unsupported operation"
      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def promote(to:)
      raise EvalError, "unsupported operation"
      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def reinterpret(to:)
      raise EvalError, "unsupported operation"
      
    end
    
    # I32#inspect shows signed value for convinience
    def inspect
      "I32(#{value_s})"
    end
  end

  class I64
    include ValueHelper

    I64_MAX = (1<<64) - 1

    attr_accessor :value #: Integer

    # returns a value interpreted as signed integer
    # @rbs return: Integer
    def value_s
      (@value >> 63).zero? ?
        @value :
        ((-@value) ^ I64_MAX) + 1
    end

    # @rbs return: String
    def packed
      [self.value].pack("L")
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def wrap(to:)
      raise EvalError, "unsupported operation"
      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def extend_(to:)
      raise EvalError, "unsupported operation"
      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def trunc_s(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def trunc_u(to:)
      raise EvalError, "unsupported operation"      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def convert(to:)
      raise EvalError, "unsupported operation"
      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def demote(to:)
      raise EvalError, "unsupported operation"
      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def promote(to:)
      raise EvalError, "unsupported operation"
      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def reinterpret(to:)
      raise EvalError, "unsupported operation"
      
    end

    # I64#inspect shows signed value
    def inspect
      "I64(#{@value})"
    end
  end

  class F32
    include ValueHelper

    attr_accessor :value #: Float    

    # @rbs return: String
    def packed
      [self.value].pack("f")
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def wrap(to:)
      raise EvalError, "unsupported operation"
      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def extend_(to:)
      raise EvalError, "unsupported operation"
      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def trunc_s(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def trunc_u(to:)
      raise EvalError, "unsupported operation"      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def convert(to:)
      raise EvalError, "unsupported operation"
      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def demote(to:)
      raise EvalError, "unsupported operation"
      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def promote(to:)
      
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def reinterpret(to:)
      raise EvalError, "unsupported operation"
      
    end

    def inspect
      "F32(#{@value})"
    end
  end

  class F64
    include ValueHelper

    attr_accessor :value #: Float    

    # @rbs return: String
    def packed
      [self.value].pack("d")
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def wrap(to:)
      raise EvalError, "unsupported operation"
      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def extend_(to:)
      raise EvalError, "unsupported operation"
      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def trunc_s(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def trunc_u(to:)
      raise EvalError, "unsupported operation"      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def convert(to:)
      raise EvalError, "unsupported operation"
      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def demote(to:)
      raise EvalError, "unsupported operation"
      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def promote(to:)
      raise EvalError, "unsupported operation"
      
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def reinterpret(to:)
      raise EvalError, "unsupported operation"
      
    end

    def inspect
      "F64(#{@value})"
    end
  end
end