# rbs_inline: enabled
module Waru
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
      when :local_get, :call
        [:u32]
      else
        []
      end
    end
  end
end