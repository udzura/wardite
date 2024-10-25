# frozen_string_literal: true
# rbs_inline: enabled

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

class WaruInstanceTest < Test::Unit::TestCase
  test "Waru::Instance#runtime" do
    bytes = IO.read(File.expand_path("../add.wasm", __FILE__))
    assert do
      wasm = ::StringIO.new(bytes)
      instance = ::Waru::BinaryLoader.load_from_buffer(wasm)
      ret = instance.runtime.call(:add, [100, 200])
      ret == 300
    end

    assert do
      wasm = ::StringIO.new(bytes)
      instance = ::Waru::BinaryLoader.load_from_buffer(wasm)
      ret = instance.runtime.add(200, 300)
      ret == 500
    end
  end
end
