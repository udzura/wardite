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
    assert_instance_of Wardite::Efflorescence::VM, Wardite::BinaryLoader.load_from_buffer(wasm).runtime
  end
end

class WarditeInstanceTest < Test::Unit::TestCase
  test "Wardite.new defaults to Efflorescence and rejects the retired stack engine" do
    path = File.expand_path("add.wasm", __dir__)
    assert_instance_of Wardite::Efflorescence::VM, Wardite.new(path: path).runtime
    assert_raise_message("unknown engine: stack") { Wardite.new(path: path, engine: :stack) }
  end

  test "exports are looked up and called by name" do
    instance = Wardite.new(path: File.expand_path("add.wasm", __dir__), enable_wasi: false)
    assert instance.runtime.callable?(:add)
    assert_false instance.runtime.callable?(:missing_export)
    assert_kind_of Wardite::WasmFunction, instance.exports["add"]
    assert_nil instance.exports["missing_export"]
    [instance, instance.runtime, instance.exports].each do |receiver|
      assert_false receiver.respond_to?(:add)
      assert_raise(NoMethodError) { receiver.public_send(:add, 2, 3) }
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
  end
end
