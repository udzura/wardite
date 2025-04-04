# rbs_inline: enabled

module Wardite
  module Wasi
    class Dirent
      attr_reader :path #: String
      attr_reader :ino #: Integer
      attr_reader :type #: Integer
      
      # @rbs path: String
      # @rbs ino: Integer
      # @rbs type: Integer
      # @rbs return: void
      def initialize(path, ino, type)
        @path = path
        @ino = ino
        @type = type
      end
    end

    class DirentCache
      attr_reader :entries #: Array[Dirent]
      attr_accessor :eof #: bool
      
      # @rbs path: String
      # @rbs return: void
      def initialize(path)
        @entries = []
        Dir.entries(path).sort.each do |entry|
          case entry
          when "."
            @entries << Dirent.new(entry, File.stat(path).ino, FILETYPE_DIRECTORY)
          when ".."
            @entries << Dirent.new(entry, 0, FILETYPE_DIRECTORY)
          else
            full_path = File.join(path, entry)
            type = case File.ftype(full_path)
                   when "directory" then FILETYPE_DIRECTORY
                   when "file"      then FILETYPE_REGULAR_FILE
                   when "link"      then FILETYPE_SYMBOLIC_LINK
                   else FILETYPE_UNKNOWN
                   end
            @entries << Dirent.new(entry, File.stat(full_path).ino, type)
          end
        end

        @eof = false
      end

      # @rbs buf_len: Integer
      # @rbs cookie: Integer
      # @rbs return: [String, bool]
      def fetch_entries_binary(buf_len, cookie)
        # d_next is the index of the next file in the list, so it should
        # always be one higher than the requested cookie.
        d_next = cookie + 1
        buf = ""
        entries_slice = entries[cookie..-1]
        return "", false if entries_slice.nil? || entries_slice.empty?

        entries_slice.each do |entry|
          data = make_dirent_pack1(d_next, entry.ino, entry.path.size, entry.type, entry.path)
          if buf.size + data.size > buf_len
            # truncated
            return buf, true
          end
          buf += data
          d_next += 1
        end
        
        return buf, false
      end

      # @rbs d_next: Integer
      # @rbs ino: Integer
      # @rbs name_len: Integer
      # @rbs type: Integer
      # @rbs name: String
      # @rbs return: String
      def make_dirent_pack1(d_next, ino, name_len, type, name)
        data = [d_next, ino, name_len, type].pack("Q! Q! I! I!")
        data += name
        data
      end
    end
  end
end