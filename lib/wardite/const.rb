# rbs_inline: enabled
module Wardite
  module Const
    # Section Code
    # @see https://www.w3.org/TR/wasm-core-1/#sections%E2%91%A0
    SectionCustom   = 0x0 #: Integer
    SectionType     = 0x1 #: Integer
    SectionImport   = 0x2 #: Integer
    SectionFunction = 0x3 #: Integer
    SectionTable    = 0x4 #: Integer
    SectionMemory   = 0x5 #: Integer
    SectionGlobal   = 0x6 #: Integer
    SectionExport   = 0x7 #: Integer
    SectionStart    = 0x8 #: Integer
    SectionElement  = 0x9 #: Integer
    SectionCode     = 0xa #: Integer
    SectionData     = 0xb #: Integer
  end
  include Const
end