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
  test "global imports retain identity, initialization order and independent function indices" do
    wat = <<~WAT
      (module
        (import "env" "cell" (global $a (mut i32)))
        (import "env" "double" (func $double (param i32) (result i32)))
        (import "env" "cell" (global $b (mut i32)))
        (import "env" "seed" (global $seed i32))
        (global $initial i32 (global.get $seed))
        (func (export "run") (result i32)
          (global.set $a (call $double (global.get $initial)))
          (global.get $b)))
    WAT
    cell = Wardite::Global.numeric(:i32, true)
    seed = Wardite::Global.numeric(:i32, false)
    seed.value = Wardite::I32(21)
    host = Wardite::HashModule.new({double: ->(_store, args) { args.first.value * 2 }},
      {cell: cell, seed: seed})
    instance = Wardite.new(buffer: make_buffer_from_wat(wat), import_object: {env: host}, enable_wasi: false)
    assert_equal 42, instance.runtime.call_unboxed("run", [])
    assert_equal 42, cell.value.value
    assert_same cell, instance.store.globals.fetch(1)
  end

  test "global imports require matching value type and mutability" do
    bytes = make_buffer_from_wat('(module (import "env" "x" (global i64)))').string
    [Wardite::Global.numeric(:i32, false), Wardite::Global.numeric(:i64, true)].each do |wrong|
      host = Wardite::HashModule.new({}, {x: wrong})
      assert_raise(Wardite::LoadError) do
        Wardite.new(buffer: StringIO.new(bytes), import_object: {env: host}, enable_wasi: false)
      end
    end
  end

end
