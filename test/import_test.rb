# frozen_string_literal: true

require "test_helper"

class WarditeImportTest < Test::Unit::TestCase
  test "host imports work without loading WASI" do
    code = <<~WAT
      (module
        (import "env" "double" (func $double (param i32) (result i32)))
        (func (export "twice") (param i32) (result i32)
          local.get 0
          call $double))
    WAT
    double = ->(_store, args) { args.fetch(0).value * 2 }
    registries = [
      {env: {double: double}},
      Hash.new { |_, _name| Wardite::HashModule.new(Hash.new { |_, _key| double }) }
    ]
    registries.each do |registry|
      instance = Wardite::BinaryLoader.load_from_buffer(
        make_buffer_from_wat(code), import_object: registry, enable_wasi: false
      )
      assert_equal 246, instance.runtime.call("twice", [123]).value
    end
    assert_raise(NameError) do
      Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code), enable_wasi: false)
    end
  end
end
