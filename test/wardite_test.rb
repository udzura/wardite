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
  test "respond_to? accepts the private visibility flag" do
    bytes = File.binread(File.expand_path("add.wasm", __dir__))
    instance = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false)

    [instance.runtime, instance.exports].each do |receiver|
      assert_equal true, receiver.respond_to?(:add)
      assert_equal true, receiver.respond_to?("add", false)
      assert_equal true, receiver.respond_to?(:add, true)
      assert_equal true, receiver.respond_to?(:to_s, false)
      assert_equal false, receiver.respond_to?(:initialize, false)
      assert_equal true, receiver.respond_to?(:initialize, true)
      assert_equal false, receiver.respond_to?(:missing_export, false)
      assert_equal false, receiver.respond_to?(:missing_export, true)
    end
  end

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
