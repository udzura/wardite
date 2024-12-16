# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "wardite"
require "tmpdir"
require "stringio"

module Kernel
  def make_buffer_from_wat(code)
    Dir.mktmpdir("__wardite__test__") do |dir|
      Dir.chdir dir
      fname = "wtest-#{$$}-#{Time.now.to_i}"
      IO.write("#{fname}.wat", code)
      system "wasm-tools parse -o #{fname}.wasm #{fname}.wat"

      StringIO.new(IO.read("#{fname}.wasm"))
    end
  end
  module_function :make_buffer_from_wat
end

require "test-unit"
