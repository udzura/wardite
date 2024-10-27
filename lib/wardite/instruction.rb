# rbs_inline: enabled
module Wardite
  class Op
    attr_accessor :code #: Symbol

    attr_accessor :operand #: Array[Object]

    # @rbs code: Symbol
    # @rbs operand: Array[Object]
    def initialize(code, operand)
      @code = code
      @operand = operand
    end

    # @rbs chr: String
    # @rbs return: Symbol
    def self.to_sym(chr)
      case chr
      when "\u000b"
        :end
      when "\u0010"
        :call
      when "\u0020"
        :local_get
      when "\u0021"
        :local_set
      when "\u0036"
        :i32_store
      when "\u0041"
        :i32_const
      when "\u006a"
        :i32_add
      else
        raise NotImplementedError, "unimplemented: #{chr.inspect}"
      end
    end

    # @rbs chr: Symbol
    # @rbs return: Array[Symbol]
    def self.operand_of(code)
      case code
      when :local_get, :local_set, :call
        [:u32]
      when :i32_const
        [:i32]
      when :i32_store
        [:u32, :u32]
      else
        []
      end
    end

    # @see https://www.w3.org/TR/wasm-core-1/#value-types%E2%91%A2
    # @rbs code: Integer
    # @rbs return: Symbol
    def self.i2type(code)
      case code
      when 0x7f
        :i32
      when 0x7e
        :i64
      when 0x7d
        :f32
      when 0x7c
        :f64
      else
        raise "unknown type code #{code}"
      end
    end
  end
end