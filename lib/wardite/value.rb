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

    # @rbs return: Integer
    def memsize
      32
    end

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
      [self.value].pack("I!")
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def wrap(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def extend_s(to:)
      raise EvalError, "unsupported operation" if to != :i64
      I64(value_s)
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def extend_u(to:)
      raise EvalError, "unsupported operation" if to != :i64
      I64(value)
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
    def convert_s(to:)
      case to
      when :f32
        F32(value_s.to_f)
      when :f64
        F64(value_s.to_f)
      else
        raise EvalError, "unsupported operation"
      end
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def convert_u(to:)
      case to
      when :f32
        F32(value.to_f)
      when :f64
        F64(value.to_f)
      else
        raise EvalError, "unsupported operation"
      end
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
      raise EvalError, "unsupported operation" if to != :f32
      v = [value].pack("I!").unpack("f")[0]
      raise EvalError, "[BUG] String#unpack is broke, really?" if !v.is_a?(Float)
      F32(v)
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

    # @rbs return: Integer
    def memsize
      64
    end

    # returns a value interpreted as signed integer
    # @rbs return: Integer
    def value_s
      (@value >> 63).zero? ?
        @value :
        ((-@value) ^ I64_MAX) + 1
    end

    # @rbs return: String
    def packed
      [self.value].pack("L!")
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def wrap(to:)
      if to != :i32
        raise EvalError, "unsupported operation #{to}"
      end
      I32(value % (1 << 32))
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def extend_s(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def extend_u(to:)
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
    def convert_s(to:)
      case to
      when :f32
        F32(value_s.to_f)
      when :f64
        F64(value_s.to_f)
      else
        raise EvalError, "unsupported operation"
      end
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def convert_u(to:)
      case to
      when :f32
        F32(value.to_f)
      when :f64
        F64(value.to_f)
      else
        raise EvalError, "unsupported operation"
      end
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
      raise EvalError, "unsupported operation" if to != :f64
      v = [value].pack("L!").unpack("d")[0]
      raise EvalError, "[BUG] String#unpack is broke, really?" if !v.is_a?(Float)
      F32(v)
    end

    # I64#inspect shows signed value
    def inspect
      "I64(#{@value})"
    end
  end

  class F32
    include ValueHelper

    attr_accessor :value #: Float

    # @rbs return: Integer
    def memsize
      32
    end

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
    def extend_s(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def extend_u(to:)
      raise EvalError, "unsupported operation"
    end

    # @todo need more testcase...
    # @see https://webassembly.github.io/spec/core/exec/numerics.html#xref-exec-numerics-op-trunc-s-mathrm-trunc-mathsf-s-m-n-z
    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def trunc_s(to:)
      v = value.to_i
      case to
      when :i32
        if v >= 0
          I32(v & (I32::I32_MAX >> 1))
        else
          v = v & I32::I32_MAX
          if (v >> 31).zero?
            raise EvalError, "[undefined behavior] detected overflow: #{value}"
          end
          I32(v)
        end
      when :i64
        if v >= 0
          I64(v & (I64::I64_MAX >> 1))
        else
          v = v & I64::I64_MAX
          if (v >> 31).zero?
            raise EvalError, "[undefined behavior] detected overflow: #{value}"
          end
          I64(v)
        end
      else
        raise EvalError, "unsupported operation to: #{to}"
      end
    end

    # @see https://webassembly.github.io/spec/core/exec/numerics.html#xref-exec-numerics-op-trunc-u-mathrm-trunc-mathsf-u-m-n-z
    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def trunc_u(to:)
      v = value.to_i
      if v < 0
        raise EvalError, "[undefined behavior] unexpected negative value"
      end
      case to
      when :i32
        v = v & I32::I32_MAX
        I32(v)
      when :i64
        v = v & I64::I64_MAX
        I64(v)
      else
        raise EvalError, "unsupported operation to: #{to}"
      end
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def convert_s(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def convert_u(to:)
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
      raise EvalError, "unsupported operation" if to != :f64
      F64(value)
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def reinterpret(to:)
      raise EvalError, "unsupported operation" if to != :i32
      v = [value].pack("f").unpack("I!")[0]
      raise EvalError, "[BUG] String#unpack is broke, really?" if !v.is_a?(Integer)
      I32(v)
    end

    def inspect
      "F32(#{@value})"
    end
  end

  class F64
    include ValueHelper

    attr_accessor :value #: Float

    # @rbs return: Integer
    def memsize
      64
    end

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
    def extend_s(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def extend_u(to:)
      raise EvalError, "unsupported operation"
    end

    # @see the same as F32
    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def trunc_s(to:)
      v = value.to_i
      case to
      when :i32
        if v >= 0
          I32(v & (I32::I32_MAX >> 1))
        else
          v = v & I32::I32_MAX
          if (v >> 31).zero?
            raise EvalError, "[undefined behavior] detected overflow: #{value}"
          end
          I32(v)
        end
      when :i64
        if v >= 0
          I64(v & (I64::I64_MAX >> 1))
        else
          v = v & I64::I64_MAX
          if (v >> 31).zero?
            raise EvalError, "[undefined behavior] detected overflow: #{value}"
          end
          I64(v)
        end
      else
        raise EvalError, "unsupported operation to: #{to}"
      end
    end

    # @see the same as F32
    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def trunc_u(to:)
      v = value.to_i
      if v < 0
        raise EvalError, "[undefined behavior] unexpected negative value"
      end
      case to
      when :i32
        v = v & I32::I32_MAX
        I32(v)
      when :i64
        v = v & I64::I64_MAX
        I64(v)
      else
        raise EvalError, "unsupported operation to: #{to}"
      end
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def convert_s(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def convert_u(to:)
      raise EvalError, "unsupported operation"
    end

    # @todo no loss of digits...
    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def demote(to:)
      raise EvalError, "unsupported operation" if to != :f32
      F32(value)
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def promote(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: I32|I64|F32|F64
    def reinterpret(to:)
      raise EvalError, "unsupported operation" if to != :i64
      v = [value].pack("d").unpack("L!")[0]
      raise EvalError, "[BUG] String#unpack is broke, really?" if !v.is_a?(Integer)
      I64(v)
    end

    def inspect
      "F64(#{@value})"
    end
  end
end