# frozen_string_literal: true
# rbs_inline: enabled

require_relative "waru/version"

module Waru
  module BinaryLoader
    # @rbs buf: IO::Buffer
    # @rbs return: Instance
    def self.load_from_buffer(buf)
      return Instance.new
    end
  end

  class Instance
  end

  class Error < StandardError; end
  # Your code goes here...
end
