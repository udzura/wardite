# frozen_string_literal: true

require "test_helper"

class WaruTest < Test::Unit::TestCase
  test "VERSION" do
    assert do
      ::Waru.const_defined?(:VERSION)
    end
  end
end

class WaruBinaryLoaderTest < Test::Unit::TestCase
  test "Waru::BinaryLoader" do
    bytes = IO.read(File.expand_path("../add.wasm", __FILE__))
    wasm = ::StringIO.new(bytes)
    assert do
      ::Waru::BinaryLoader.load_from_buffer(wasm)
    end
  end
end
