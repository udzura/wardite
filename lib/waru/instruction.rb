module Waru
  class Op
    # TODO: enumerize
    # @rbs code: Symbol
    attr_accessor :code

    # @rbs Array[any]
    attr_accessor :operand

    def initialize(code, operand)
      @code = code
      @operand = operand
    end

    def self.to_sym(chr)
      case chr
      when "\u000b"
        :end
      when "\u0020"
        :local_get
      when "\u006a"
        :i32_add
      else
        raise NotImplementedError, "unimplemented: 0x0#{chr.to_s(16)}"
      end
    end

    def self.operand_of(code)
      case code
      when :local_get
        [:u32]
      else
        []
      end
    end
  end
end