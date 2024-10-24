# frozen_string_literal: true
# rbs_inline: enabled

require_relative "waru/version"
require_relative "waru/leb128"
require_relative "waru/const"

require "stringio"

module Waru
  class Section
    attr_accessor :name
   
    attr_accessor :code

    attr_accessor :size
  end

  class TypeSection < Section
    attr_accessor :defined_types

    attr_accessor :defined_results

    def initialize
      self.name = "Type"
      self.code = 0x1

      @defined_types = []
      @defined_results = []
    end
  end

  class FunctionSection < Section
    attr_accessor :func_indices

    def initialize
      self.name = "Function"
      self.code = 0x3

      @func_indices = []
    end
  end

  class CodeSection < Section
    attr_accessor :func_codes

    def initialize
      self.name = "Code"
      self.code = 0xa

      @func_codes = []
    end
  end

  class ExportSection < Section
    class ExportDesc
      attr_accessor :name
      
      attr_accessor :kind

      attr_accessor :func_index
    end

    # @rbs @exports: Hash[String, ExportDesc]
    attr_accessor :exports

    def initialize
      self.name = "Export"
      self.code = 0x7

      @exports = {}
    end

    def add_desc(&blk)
      desc = ExportDesc.new
      blk.call(desc)
      self.exports[desc.name] = desc
    end
  end

  module BinaryLoader
    extend Waru::Leb128Helpers

    # @rbs buf: File|StringIO
    # @rbs return: Instance
    def self.load_from_buffer(buf)
      @buf = buf #: File

      @version = preamble
      @sections = sections
      # TBA...

      return Instance.new
    end

    # @rbs return: Integer
    def self.preamble
      asm = @buf.read 4
      if asm != "\u0000asm"
        raise LoadError, "invalid preamble"
      end

      version = @buf.read(4)
        .to_enum(:chars)
        .with_index
        .inject(0) {|dest, (c, i)| dest | (c.ord << i*8) }
      if version != 1
        raise LoadError, "unsupported version: #{version}"
      end
      version
    end

    # @rbs return: []Section
    def self.sections
      sections = []

      loop do
        byte = @buf.read(1)
        if byte == nil
          break
        end
        code = byte.unpack("C")[0]

        section = case code
          when Waru::SectionType
            type_section
          when Waru::SectionImport
            unimplemented_skip_section(code)
          when Waru::SectionFunction
            function_section
          when Waru::SectionTable
            unimplemented_skip_section(code)
          when Waru::SectionMemory
            unimplemented_skip_section(code)
          when Waru::SectionGlobal
            unimplemented_skip_section(code)
          when Waru::SectionExport
            export_section
          when Waru::SectionStart
            unimplemented_skip_section(code)
          when Waru::SectionElement
            unimplemented_skip_section(code)
          when Waru::SectionCode
            code_section
          when Waru::SectionData
            unimplemented_skip_section(code)
          when Waru::SectionCustom
            unimplemented_skip_section(code)
          else
            raise LoadError, "unknown code: #{code}(\"#{code.to_s 16}\")"
          end

        if section
          sections << section
        end
      end
      pp sections
      sections
    end

    # @rbs return: TypeSection
    def self.type_section
      dest = TypeSection.new

      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(@buf.read(size))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        fncode = assert_read(sbuf, 1)
        if fncode != "\x60"
          raise LoadError, "not a function definition"
        end

        arglen = fetch_uleb128(sbuf)
        arg = []
        arglen.times do
          case ty = assert_read(sbuf, 1).unpack("C")[0]
          when 0x7f
            arg << :i32
          when 0x7e
            arg << :i64
          else
            raise NotImplementedError, "unsupported for now: #{ty.to_s(16).inspect}"
          end
        end
        dest.defined_types << arg

        retlen = fetch_uleb128(sbuf)
        ret = []
        retlen.times do
          case ty = assert_read(sbuf, 1).unpack("C")[0]
          when 0x7f
            ret << :i32
          when 0x7e
            ret << :i64
          else
            raise NotImplementedError, "unsupported for now: #{ty.to_s(16).inspect}"
          end
        end
        dest.defined_results << ret
      end

      dest
    end

    # @rbs return: FunctionSection
    def self.function_section
      dest = FunctionSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(@buf.read(size))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        index = fetch_uleb128(sbuf)
        dest.func_indices << index
      end
      dest
    end

    # @rbs return: CodeSection
    def self.code_section
      dest = CodeSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(@buf.read(size))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        ilen = fetch_uleb128(sbuf)
        code = assert_read(sbuf, ilen).unpack("C*")
        if code[-1] != 0x0b
          $stderr.puts "warning: instruction not ended with inst end(0x0b): 0x0#{code[-1].to_s(16)}" 
        end
        dest.func_codes << code
      end

      dest
    end

    # @rbs return: ExportSection
    def self.export_section
      dest = ExportSection.new
      size = fetch_uleb128(@buf)
      dest.size = size
      sbuf = StringIO.new(@buf.read(size))

      len = fetch_uleb128(sbuf)
      len.times do |i|
        nlen = fetch_uleb128(sbuf)
        name = assert_read(sbuf, nlen)
        kind = assert_read(sbuf, 1).unpack("C")[0]
        index = fetch_uleb128(sbuf)
        dest.add_desc do |desc|
          desc.name = name
          desc.kind = kind
          desc.func_index = index
        end
      end

      dest
    end

    # @rbs code: Integer
    # @rbs return: nil
    def self.unimplemented_skip_section(code)
      $stderr.puts "warning: unimplemented section: 0x0#{code.to_s(16)}"
      size = @buf.read(1).unpack("C")[0]
      @buf.read(size)
      nil
    end

    # @rbs sbuf: StringIO
    # @rbs n: Integer
    # @rbs return: String
    def self.assert_read(sbuf, n)
      ret = sbuf.read n
      if ret == nil || ret.size != n
        raise LoadError, "too short section size"
      end
      ret
    end
  end

  class Instance
    # @rbs @version: Integer
    attr_accessor :version
  end

  class LoadError < StandardError; end
  # Your code goes here...
end
