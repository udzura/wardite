# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    # Explicit executable input. The mapped inode must remain immutable while in use.
    class MIRArtifact
      MAGIC = "WARDWMIR".b
      VERSION = 1
      FIELDS_SIZE = 36
      PREFIX_SIZE = FIELDS_SIZE + 3 * 32
      HEADER_SIZE = PREFIX_SIZE + 32

      attr_reader :path #: String
      attr_reader :key #: String
      attr_reader :source_digest #: String
      attr_reader :payload_size #: Integer
      attr_reader :directory_bytes #: String
      attr_reader :enabled #: Array[Symbol]

      # @rbs file: File
      # @rbs verify: Symbol
      def initialize(file, verify)
        @path = file.path
        stat = file.stat
        size = stat.size
        unless stat.file? && size.between?(HEADER_SIZE + 8, HEADER_SIZE + 2 * MIRCache::MAX_BYTES)
          raise Wardite::LoadError, "invalid WMIR file size"
        end
        @map = IO::Buffer.map(file, size, 0, IO::Buffer::READONLY)
        header = @map.get_string(0, PREFIX_SIZE)
        version, format, code, mask, directory_size, payload_size, wasm_size = header.unpack("L<7", offset: 8) #: [Integer, Integer, Integer, Integer, Integer, Integer, Integer]
        unless header.start_with?(MAGIC) && version == VERSION &&
            format == MIRCache::FORMAT_VERSION && code == MIRCache::CODE_VERSION
          raise Wardite::LoadError, "incompatible WMIR format"
        end
        unless directory_size.between?(8, payload_size) && payload_size <= MIRCache::MAX_BYTES &&
            wasm_size.between?(8, MIRCache::MAX_BYTES) && HEADER_SIZE + payload_size + wasm_size == size
          raise Wardite::LoadError, "invalid WMIR lengths"
        end
        @payload_size = payload_size
        @directory_bytes = @map.get_string(HEADER_SIZE, directory_size)
        raise Wardite::LoadError, "invalid WMIR directory checksum" unless Digest::SHA256.digest(header + @directory_bytes) == @map.get_string(PREFIX_SIZE, 32)
        raise Wardite::LoadError, "unknown WMIR optimization flags" unless mask < (1 << Configuration::FEATURES.size)
        @enabled = [] #: Array[Symbol]
        Configuration::FEATURES.each_with_index { |feature, i| @enabled << feature if (mask & (1 << i)) != 0 }
        @source_digest = @map.get_string(FIELDS_SIZE, 32)
        @key = @map.get_string(FIELDS_SIZE + 32, 32)
        if verify == :sha256
          raise Wardite::LoadError, "invalid WMIR payload digest" unless Digest::SHA256.digest(@map.get_string(HEADER_SIZE, payload_size)) == @map.get_string(FIELDS_SIZE + 64, 32)
          raise Wardite::LoadError, "invalid WMIR source digest" unless Digest::SHA256.digest(@map.get_string(HEADER_SIZE + payload_size, wasm_size)) == @source_digest
        end
        file.pos = HEADER_SIZE + payload_size
      end

      # Read local declarations and jump over the instructions, which are only
      # needed when an embedding inspects the original Wasm after loading MIR.
      class CodeReader
        attr_reader :pos #: Integer

        # @rbs map: IO::Buffer
        # @rbs offset: Integer
        # @rbs size: Integer
        def initialize(map, offset, size)
          @map = map
          @pos = offset
          @limit = offset + size
          raise Wardite::LoadError, "truncated WMIR code section" if @limit > map.size
        end

        # @rbs return: Integer
        def getbyte
          raise Wardite::LoadError, "truncated WMIR local declaration" if @pos >= @limit
          value = @map.get_value(:U8, @pos) #: Integer
          @pos += 1
          value
        end

        # @rbs return: CodeSection::CodeBody
        # @rbs types: TypeSection
        def body(types)
          size = Leb128Helper.fetch_uleb128(self)
          finish = @pos + size
          section_end = @limit
          raise Wardite::LoadError, "truncated WMIR function" if finish > section_end
          @limit = finish
          body = CodeSection::CodeBody.new do |b|
            Leb128Helper.fetch_uleb128(self).times do
              b.locals_count << Leb128Helper.fetch_uleb128(self)
              b.locals_type << BinaryLoader.read_signature_type(self, types)
            end
            raise Wardite::LoadError, "empty WMIR function" if @pos == finish
            b.map_instructions(@map, @pos, finish - @pos)
          end
          @pos = finish
          @limit = section_end
          body
        end
      end

      # @rbs file: File
      # @rbs size: Integer
      # @rbs return: CodeSection
      # @rbs types: TypeSection
      def code_section(file, size, types = TypeSection.new)
        offset = file.pos
        reader = CodeReader.new(@map, offset, size)
        section = CodeSection.new
        section.size = size
        Leb128Helper.fetch_uleb128(reader).times { section.func_codes << reader.body(types) }
        raise Wardite::LoadError, "invalid WMIR code section length" unless reader.pos == offset + size
        file.pos = reader.pos
        section
      end

      # @rbs offset: Integer
      # @rbs length: Integer
      # @rbs return: String
      def record(offset, length)
        @map.get_string(HEADER_SIZE + offset, length)
      end

      # @rbs path: String
      # @rbs wasm: String
      # @rbs source_digest: String
      # @rbs key: String
      # @rbs configuration: Configuration
      # @rbs directory_size: Integer
      # @rbs payload: String
      # @rbs return: void
      def self.write(path, wasm, source_digest, key, configuration, directory_size, payload)
        mask = 0
        Configuration::FEATURES.each_with_index { |feature, i| mask |= 1 << i if configuration.enabled?(feature) }
        header = MAGIC + [VERSION, MIRCache::FORMAT_VERSION, MIRCache::CODE_VERSION, mask, directory_size, payload.bytesize, wasm.bytesize].pack("L<7")
        header << source_digest << key << Digest::SHA256.digest(payload)
        header << Digest::SHA256.digest(header + payload.byteslice(0, directory_size).to_s)
        MIRCache.publish(File.dirname(path), path, header, payload, wasm)
      end
    end
  end
end
