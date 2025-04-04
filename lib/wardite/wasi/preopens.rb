# rbs_inline: enabled

module Wardite
  module Wasi
    class PreopenedDir
      attr_reader :path #: String
      attr_reader :guest_path #: String
      attr_reader :fd #: Integer
      
      def initialize(path, guest_path, fd)
        @path = path
        @guest_path = guest_path
        @fd = fd
      end
    end
  end
end