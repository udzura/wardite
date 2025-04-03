# rbs_inline: enabled

module Wardite
  # @rbs!
  #   type wasmValue = I32 | I64 | F32 | F64

  module ValueHelper
    # @rbs value: Integer
    # @rbs return: I32
    def I32(value)
      I32.cached_or_initialize(value & I32::I32_MAX)
    end

    # @rbs value: Integer
    # @rbs return: I64
    def I64(value)
      I64.new(value & I64::I64_MAX)
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

  extend ValueHelper

  class I32
    include ValueHelper

    I32_MAX = (1<<32) - 1 #: Integer
    # value should be stored as unsigned Integer, even in I32/I64
    # when we want to access signed value, it'd be done via #value_s
    attr_accessor :value #: Integer

    # @rbs!
    #   @@i32_object_pool: Hash[Integer, I32]
    @@i32_object_pool = {} #: Hash[Integer, I32]

    # @rbs value: Integer
    # @rbs return: I32
    def self.cached_or_initialize(value)
      @@i32_object_pool[value] || I32.new(value)
    end

    # @rbs value: Integer
    def initialize(value=0)
      @value = value
    end

    # @rbs str: String
    # @rbs size: Integer|nil
    # @rbs signed: bool
    # @rbs return: I32
    def self.from_bytes(str, size: nil, signed: false)
      v = case size
        when nil
          str.unpack("I!")[0]
        when 8
          signed ? str.unpack("c")[0] : str.unpack("C")[0]
        when 16
          signed ? str.unpack("s!")[0] : str.unpack("S!")[0]
        end
      if !v.is_a?(Integer)
        raise "broken string or unsupported size: #{str.inspect} -> #{size}"
      end
      Wardite::I32(v)
    end

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
    # @rbs size: Integer|nil
    # @rbs return: String
    def packed(size: nil)
      case size
      when nil
        [self.value].pack("I!")
      when 8
        [self.value & 0xff].pack("C")
      when 16
        [self.value & 0xffff].pack("S!")
      else
        raise EvalError, "unsupported size #{size}"
      end
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def wrap(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def extend_s(to:)
      raise EvalError, "unsupported operation" if to != :i64
      I64(value_s)
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def extend_u(to:)
      raise EvalError, "unsupported operation" if to != :i64
      I64(value)
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def trunc_s(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def trunc_u(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
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
    # @rbs return: wasmValue
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
    # @rbs return: wasmValue
    def demote(to:)
      raise EvalError, "unsupported operation"

    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def promote(to:)
      raise EvalError, "unsupported operation"

    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def reinterpret(to:)
      raise EvalError, "unsupported operation" if to != :f32
      v = [value].pack("I!").unpack("f")[0]
      raise EvalError, "[BUG] String#unpack is broke, really?" if !v.is_a?(Float)
      F32(v)
    end

    # @rbs from: Symbol
    # @rbs to: Symbol
    # @rbs return: wasmValue
    def extendN_s(from:, to:)
      src_value = case from
      when :i8
        base = value & 0xff
        (base >> 8).zero? ?
          base :
          ((-base) ^ 0xff) + 1
      when :i16
        base = value & 0xffff
        (base >> 15).zero? ?
          base :
          ((-base) ^ 0xffff) + 1
      when :i32
        value_s
      else
        raise EvalError, "unsupported value size"
      end

      case to
      when :i32
        I32(src_value)
      when :i64
        I64(src_value)
      else
        raise EvalError, "unsupported value size"
      end
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def trunc_sat_u(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def trunc_sat_s(to:)
      raise EvalError, "unsupported operation"
    end

    # I32#inspect shows signed value for convinience
    def inspect
      "I32(#{value_s})"
    end

    def ==(other)
      return self.class == other.class && self.value == other.value
    end

    (0..64).each do |value|
      @@i32_object_pool[value] = I32.new(value)
    end
    value = -1 & I32::I32_MAX
    @@i32_object_pool[value] = I32.new(value)
  end

  class I64
    include ValueHelper

    I64_MAX = (1<<64) - 1 #: Integer

    attr_accessor :value #: Integer

    # @rbs value: Integer
    def initialize(value=0)
      @value = value
    end

    # @rbs str: String
    # @rbs size: Integer|nil
    # @rbs signed: bool
    # @rbs return: I64
    def self.from_bytes(str, size: nil, signed: false)
      v = case size
        when nil
          str.unpack("L!")[0]
        when 8
          signed ? str.unpack("c")[0] : str.unpack("C")[0]
        when 16
          signed ? str.unpack("s!")[0] : str.unpack("S!")[0]
        when 32
          signed ? str.unpack("i!")[0] : str.unpack("I!")[0]
        end
      if !v.is_a?(Integer)
        raise "broken string or unsupported size: #{str.inspect} -> #{size}"
      end
      Wardite::I64(v)
    end

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

    # @rbs size: Integer|nil
    # @rbs return: String
    def packed(size: nil)
      case size
      when nil
        [self.value].pack("L!")
      when 8
        [self.value & 0xff].pack("C")
      when 16
        [self.value & 0xffff].pack("S!")
      when 32
        [self.value & 0xffffffff].pack("I!")
      else
        raise EvalError, "unsupported size #{size}"
      end
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def wrap(to:)
      if to != :i32
        raise EvalError, "unsupported operation #{to}"
      end
      I32(value % (1 << 32))
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def extend_s(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def extend_u(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def trunc_s(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def trunc_u(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
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
    # @rbs return: wasmValue
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
    # @rbs return: wasmValue
    def demote(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def promote(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def reinterpret(to:)
      raise EvalError, "unsupported operation" if to != :f64
      v = [value].pack("L!").unpack("d")[0]
      raise EvalError, "[BUG] String#unpack is broke, really?" if !v.is_a?(Float)
      F64(v)
    end

    # @rbs from: Symbol
    # @rbs to: Symbol
    # @rbs return: wasmValue
    def extendN_s(from:, to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def trunc_sat_u(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def trunc_sat_s(to:)
      raise EvalError, "unsupported operation"
    end

    # I64#inspect shows signed value
    def inspect
      "I64(#{@value})"
    end
 
    def ==(other)
      return self.class == other.class && self.value == other.value
    end
  end

  class F32
    include ValueHelper

    attr_accessor :value #: Float

    # @rbs str: String
    # @rbs return: F32
    def self.from_bytes(str)
      v = str.unpack("e")[0]
      if !v.is_a?(Float)
        raise "broken string or unsupported size: #{str.inspect} -> 4"
      end
      Wardite::F32(v)
    end

    # @rbs return: Integer
    def memsize
      32
    end

    # @rbs return: :positive|:negative
    def sign
      upper = [0.0].pack("G")[0]&.ord&.<<(7)
      if !upper
        raise "[BUG] Array#pack looks broken?"
      end
      upper.zero? ? :positive : :negative
    end

    # @rbs size: Integer|nil
    # @rbs return: String
    def packed(size: nil)
      [self.value].pack("e")
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def wrap(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def extend_s(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def extend_u(to:)
      raise EvalError, "unsupported operation"
    end

    # @todo need more testcase...
    # @see https://webassembly.github.io/spec/core/exec/numerics.html#xref-exec-numerics-op-trunc-s-mathrm-trunc-mathsf-s-m-n-z
    # @see copy this impl to F64 when changed
    # @rbs to: Symbol
    # @rbs saturating: bool
    # @rbs return: wasmValue
    def trunc_s(to:, saturating: false)
      v = value.to_i
      case to
      when :i32
        if v >= 0
          i32_signed_max = I32::I32_MAX >> 1
          if saturating
            v = i32_signed_max if v > i32_signed_max
          else
            v = v & i32_signed_max
          end
          I32(v & i32_signed_max)
        else
          i32_signed_min = -(I32::I32_MAX >> 1) - 1
          if saturating
            v = i32_signed_min if v < i32_signed_min
          else
            v = v & I32::I32_MAX
            if (v >> 31).zero?
              raise EvalError, "[undefined behavior] detected overflow: #{value}"
            end
          end
          I32(v)
        end
      when :i64
        if v >= 0
          i64_signed_max = I64::I64_MAX >> 1
          if saturating
            v = i64_signed_max if v > i64_signed_max
          else
            v = v & i64_signed_max
          end
          I64(v & i64_signed_max)
        else
          i64_signed_min = -(I64::I64_MAX >> 1) - 1
          if saturating
            v = i64_signed_min if v < i64_signed_min
          else
            v = v & I64::I64_MAX
            if (v >> 63).zero?
              raise EvalError, "[undefined behavior] detected overflow: #{value}"
            end
          end
          I64(v)
        end
      else
        raise EvalError, "unsupported operation to: #{to}"
      end
    end

    # @see https://webassembly.github.io/spec/core/exec/numerics.html#xref-exec-numerics-op-trunc-u-mathrm-trunc-mathsf-u-m-n-z
    # @see copy this impl to F64 when changed
    # @rbs to: Symbol
    # @rbs sturating: bool
    # @rbs return: wasmValue
    def trunc_u(to:, saturating: false)
      v = value.to_i
      if v < 0
        if saturating
          v = 0
        else
          raise EvalError, "[undefined behavior] unexpected negative value"
        end
      end
      case to
      when :i32
        if saturating
          v = I32::I32_MAX if v > I32::I32_MAX
        else
          v = v & I32::I32_MAX
        end
        I32(v)
      when :i64
        if saturating
          v = I64::I64_MAX if v > I64::I64_MAX
        else
          v = v & I64::I64_MAX
        end
        I64(v)
      else
        raise EvalError, "unsupported operation to: #{to}"
      end
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def convert_s(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def convert_u(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def demote(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def promote(to:)
      raise EvalError, "unsupported operation" if to != :f64
      F64(value)
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def reinterpret(to:)
      raise EvalError, "unsupported operation" if to != :i32
      v = [value].pack("f").unpack("I!")[0]
      raise EvalError, "[BUG] String#unpack is broke, really?" if !v.is_a?(Integer)
      I32(v)
    end

    # @rbs from: Symbol
    # @rbs to: Symbol
    # @rbs return: wasmValue
    def extendN_s(from:, to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def trunc_sat_u(to:)
      trunc_u(to: to, saturating: true)
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def trunc_sat_s(to:)
      trunc_s(to: to, saturating: true)
    end

    def inspect
      "F32(#{@value})"
    end

    def ==(other)
      return self.class == other.class && self.value == other.value
    end
  end

  class F64
    include ValueHelper

    attr_accessor :value #: Float

    # @rbs str: String
    # @rbs return: F64
    def self.from_bytes(str)
      v = str.unpack("E")[0]
      if !v.is_a?(Float)
        raise "broken string or unsupported size: #{str.inspect} -> 8"
      end
      Wardite::F64(v)
    end

    # @rbs return: Integer
    def memsize
      64
    end

    # @rbs return: :positive|:negative
    def sign
      upper = [0.0].pack("G")[0]&.ord&.<<(7)
      if !upper
        raise "[BUG] Array#pack looks broken?"
      end
      upper.zero? ? :positive : :negative
    end

    # @rbs size: Integer|nil
    # @rbs return: String
    def packed(size: nil)
      [self.value].pack("E")
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def wrap(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def extend_s(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def extend_u(to:)
      raise EvalError, "unsupported operation"
    end

    # @see the same as F32
    # @rbs to: Symbol
    # @rbs saturating: bool
    # @rbs return: wasmValue
    def trunc_s(to:, saturating: false)
      v = value.to_i
      case to
      when :i32
        if v >= 0
          i32_signed_max = I32::I32_MAX >> 1
          if saturating
            v = i32_signed_max if v > i32_signed_max
          else
            v = v & i32_signed_max
          end
          I32(v & i32_signed_max)
        else
          i32_signed_min = -(I32::I32_MAX >> 1) - 1
          if saturating
            v = i32_signed_min if v < i32_signed_min
          else
            v = v & I32::I32_MAX
            if (v >> 31).zero?
              raise EvalError, "[undefined behavior] detected overflow: #{value}"
            end
          end
          I32(v)
        end
      when :i64
        if v >= 0
          i64_signed_max = I64::I64_MAX >> 1
          if saturating
            v = i64_signed_max if v > i64_signed_max
          else
            v = v & i64_signed_max
          end
          I64(v & i64_signed_max)
        else
          i64_signed_min = -(I64::I64_MAX >> 1) - 1
          if saturating
            v = i64_signed_min if v < i64_signed_min
          else
            v = v & I64::I64_MAX
            if (v >> 63).zero?
              raise EvalError, "[undefined behavior] detected overflow: #{value}"
            end
          end
          I64(v)
        end
      else
        raise EvalError, "unsupported operation to: #{to}"
      end
    end

    # @see the same as F32
    # @rbs to: Symbol
    # @rbs saturating: bool
    # @rbs return: wasmValue
    def trunc_u(to:, saturating: false)
      v = value.to_i
      if v < 0
        if saturating
          v = 0
        else
          raise EvalError, "[undefined behavior] unexpected negative value"
        end
      end
      case to
      when :i32
        if saturating
          v = I32::I32_MAX if v > I32::I32_MAX
        else
          v = v & I32::I32_MAX
        end
        I32(v)
      when :i64
        if saturating
          v = I64::I64_MAX if v > I64::I64_MAX
        else
          v = v & I64::I64_MAX
        end
        I64(v)
      else
        raise EvalError, "unsupported operation to: #{to}"
      end
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def convert_s(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def convert_u(to:)
      raise EvalError, "unsupported operation"
    end

    # @todo no loss of digits...
    # @rbs to: Symbol
    # @rbs return: wasmValue
    def demote(to:)
      raise EvalError, "unsupported operation" if to != :f32
      F32(value)
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def promote(to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def reinterpret(to:)
      raise EvalError, "unsupported operation" if to != :i64
      v = [value].pack("d").unpack("L!")[0]
      raise EvalError, "[BUG] String#unpack is broke, really?" if !v.is_a?(Integer)
      I64(v)
    end

    # @rbs from: Symbol
    # @rbs to: Symbol
    # @rbs return: wasmValue
    def extendN_s(from:, to:)
      raise EvalError, "unsupported operation"
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def trunc_sat_u(to:)
      trunc_u(to: to, saturating: true)
    end

    # @rbs to: Symbol
    # @rbs return: wasmValue
    def trunc_sat_s(to:)
      trunc_s(to: to, saturating: true)
    end

    def inspect
      "F64(#{@value})"
    end

    def ==(other)
      return self.class == other.class && self.value == other.value
    end
  end
end