module Waru
  module Const
    # Section Code
    # @see https://www.w3.org/TR/wasm-core-1/#sections%E2%91%A0
    SectionCustom = 0x0
    SectionType = 0x1
    SectionImport = 0x2
    SectionFunction = 0x3
    SectionTable = 0x4
    SectionMemory = 0x5
    SectionGlobal = 0x6
    SectionExport = 0x7
    SectionStart = 0x8
    SectionElement = 0x9
    SectionCode = 0xa
    SectionData = 0xb
  end
  include Const
end