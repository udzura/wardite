# frozen_string_literal: true
# rbs_inline: enabled

require "test_helper"

class WarditeTest < Test::Unit::TestCase
  test "VERSION" do
    assert do
      ::Wardite.const_defined?(:VERSION)
    end
  end
end

class WarditeBinaryLoaderTest < Test::Unit::TestCase
  test "Wardite::BinaryLoader" do
    bytes = IO.read(File.expand_path("../add.wasm", __FILE__))
    wasm = ::StringIO.new(bytes)
    assert do
      ::Wardite::BinaryLoader.load_from_buffer(wasm)
    end
  end
end

class WarditeInstanceTest < Test::Unit::TestCase
  test "Wardite::Instance#runtime" do
    bytes = IO.read(File.expand_path("../add.wasm", __FILE__))
    assert do
      wasm = ::StringIO.new(bytes)
      instance = ::Wardite::BinaryLoader.load_from_buffer(wasm)
      ret = instance.runtime.call(:add, [100, 200])
      ret.value == 300
    end

    assert do
      wasm = ::StringIO.new(bytes)
      instance = ::Wardite::BinaryLoader.load_from_buffer(wasm)
      ret = instance.runtime.add(200, 300)
      ret.value == 500
    end
  end
end
