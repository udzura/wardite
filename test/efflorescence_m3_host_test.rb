# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"

class EfflorescenceM3HostTest < Test::Unit::TestCase
  include EfflorescenceHelper

  test "host calls preserve argument order, live locals and the defined index space" do
    wat = <<~WAT
      (module
        (import "env" "zero" (func $zero (result i32)))
        (import "env" "one" (func $one (param i32)))
        (import "env" "many" (func $many (param i32 i32 i32) (result i32)))
        (start $start)
        (func $start call $zero call $one)
        (func (export "run") (param i32) (result i32)
          local.get 0 call $forward local.get 0 i32.add)
        (func $forward (param i32) (result i32)
          i32.const 42 local.get 0 i32.const -1 call $many))
    WAT
    calls = []
    saved = []
    hosts = {env: {
      zero: ->(_store, args) { calls << args.map(&:value); -2 },
      one: ->(_store, args) { calls << args.map(&:value); nil },
      many: ->(_store, args) do
        calls << args.map(&:value)
        args[0].value = 10
        saved << args
        args.clear
        Wardite::I32.new(-1)
      end
    }}
    instance = load_efflorescence(wat, import_object: hosts)
    vm = instance.runtime
    assert_equal 8, vm.call_unboxed("run", [9])
    assert_equal [[], [0xfffffffe], [42, 9, 0xffffffff]], calls
    assert_equal [[]], saved
    assert_equal [3, 4, 5], vm.ir.functions.map(&:index)
    assert_equal [0, 1, 2], vm.ir.functions.map(&:pool_index)
    assert_raise(Wardite::EvalError) { vm.ir.function_at(0) }
    assert_not_same vm.semantic_ir.hosts[0], vm.ir.hosts[0]
    assert_not_same vm.semantic_ir.entries[0].result_types, vm.ir.entries[0].result_types
  end

  test "both engines instantiate and reexport imports without function or code sections" do
    wat = '(module (import "env" "inc" (func $inc (param i32) (result i32))) (export "inc" (func $inc)))'
    bytes = compile_efflorescence_wat(wat)
    [:stack, :efflorescence].each do |engine|
      instance = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), engine: engine, enable_wasi: false,
        import_object: {env: {inc: ->(_store, args) { args[0].value + 1 }}})
      assert_equal 12, instance.runtime.call(:inc, [11]).value
      if engine == :efflorescence
        assert_equal 0, instance.runtime.call_unboxed(:inc, [-1])
        assert_raise(Wardite::ArgumentError) { instance.runtime.call_unboxed(:inc, [1.0]) }
        assert_raise(Wardite::ArgumentError) { instance.runtime.call_unboxed(:inc, []) }
      end
    end
  end

  test "profiling an imported export counts one host call and no frames" do
    vm = load_efflorescence('(module (import "env" "one" (func $one (result i32))) (export "one" (func $one)))',
      mir_profile: true, import_object: {env: {one: ->(_store, _args) { 1 }}}).runtime
    assert_equal 1, vm.call_unboxed(:one, [])
    metrics = vm.metrics
    assert_equal [1, 0, 1, 0, 0],
      [metrics.host_calls, metrics.indirect_calls, metrics.function_entries, metrics.frames_created, metrics.dispatches]
  end

  test "all imports are linked before start and unsupported kinds or types are rejected" do
    started = []
    init = ->(_store, _args) { started << true; nil }
    wat = '(module (import "env" "init" (func $init)) (import "env" "missing" (func)) (start $init))'
    assert_raise(NameError) { load_efflorescence(wat) }
    assert_raise(NameError) { load_efflorescence(wat, import_object: {env: {init: init}}) }
    assert_empty started
    assert_raise(Wardite::Efflorescence::UnsupportedFeature) do
      load_efflorescence('(module (import "env" "unused" (func (param f64))))')
    end
    ['(memory 1)', '(table 1 funcref)', '(global i32)'].each do |kind|
      assert_raise(Wardite::LoadError) { load_efflorescence("(module (import \"env\" \"x\" #{kind}))") }
    end
    ['(param i32)', '(result i32)'].each do |signature|
      assert_raise(Wardite::LoadError) do
        load_efflorescence("(module (import \"env\" \"init\" (func $init #{signature})) (start $init))",
          import_object: {env: {init: init}})
      end
    end
    assert_empty started
    assert_raise(Wardite::Efflorescence::TranslationError) do
      load_efflorescence('(module (func unreachable call 7))')
    end
    instance = load_efflorescence('(module (import "env" "init" (func $init)) (export "init" (func $init)) (start $init))',
      import_object: {env: {init: init}})
    assert_equal [true], started
    assert_nil instance.runtime.call_unboxed(:init, [])
    assert_equal [true, true], started
  end

  test "ABI mismatches execute once and cannot be replaced by a zero return" do
    [nil, 0.0, [], Wardite::I64.new(7)].each do |invalid|
      assert_abi_failure("(result i32)", invalid)
    end
    assert_abi_failure("", 0)
  end

  def assert_abi_failure(result_type, invalid)
    calls = 0
    host = ->(_store, _args) { calls += 1; invalid }
    instance = load_efflorescence(<<~WAT, import_object: {env: {bad: host}})
      (module
        (import "env" "bad" (func $bad #{result_type}))
        (export "bad" (func $bad))
        (func (export "run") #{result_type} call $bad)
        (func (export "ok") (result i32) i32.const 17))
    WAT
    [:run, :bad].each do |name|
      assert_raise_message(/host ABI result mismatch/) { instance.runtime.call_unboxed(name, []) }
    end
    assert_equal 2, calls
    assert_equal 17, instance.runtime.call_unboxed(:ok, [])
  end
end
