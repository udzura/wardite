# rbs_inline: enabled

module Wardite
  class Op
    attr_accessor :namespace #: Symbol

    attr_accessor :code #: Symbol

    # TODO: add types of potential operands
    attr_accessor :operand #: Array[Integer|Float|Block]

    # @rbs namespace: Symbol
    # @rbs code: Symbol
    # @rbs operand: Array[Integer|Float|Block]
    def initialize(namespace, code, operand)
      @namespace = namespace      
      @code = code
      @operand = operand
    end

    # @rbs chr: String
    # @rbs return: [Symbol, Symbol]
    def self.to_sym(chr)
      code = case chr
        when "\u0004"
          :if
        when "\u000b"
          :end
        when "\u000f"
          :return
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
        when "\u0048"
          :i32_lts
        when "\u004d"
          :i32_leu
        when "\u006a"
          :i32_add
        when "\u006b"
          :i32_sub
        else
          raise NotImplementedError, "unimplemented: #{"%04x" % chr.ord}"
        end
      # opcodes equal to or larger than are "convert" ops
      if chr.ord >= 0xa7
        return [:convert, code]
      end

      prefix = code.to_s.split("_")[0]
      case prefix
      when "i32", "i64", "f32", "f64"
        [prefix.to_sym, code]
      else
        [:default, code]
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
      when :if
        [:u8_block]
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