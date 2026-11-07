# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"
require_relative "support/efflorescence_m3_cases"

class EfflorescenceM3BoundaryTest < Test::Unit::TestCase
  include EfflorescenceHelper

  E = Wardite::Efflorescence
  OP = E::Opcode

  REENTRY_WAT = <<~WAT.freeze
    (module
      (type $callback_t (func (param i32) (result i32)))
      (import "env" "callback" (func $callback (type $callback_t)))
      (table 2 funcref)
      (elem (i32.const 0) func $callback $throw)
      (tag $tag)
      (global $log (mut i32) (i32.const 0))
      (func $throw (export "throw") (type $callback_t) throw $tag)
      (func (export "log") (result i32) global.get $log)
      (func $inner (export "inner") (param i32) (result i32)
        local.get 0 i32.eqz if i32.const 11 return end
        local.get 0 i32.const 1 i32.sub call $inner i32.const 1 i32.add)
      (func (export "outer") (param i32 i32) (result i32) (local i32)
        local.get 0 local.set 2
        i32.const 80 local.get 0 i32.add global.set $log
        block $caught
          try_table (result i32) (catch_all $caught)
            local.get 1
            if (result i32)
              local.get 0 i32.const 0 call_indirect (type $callback_t)
            else
              local.get 0 call $callback
            end
            local.get 2 i32.add
            local.get 0 i32.const 1 i32.eq
            if
              i32.const 0 i32.const 1 call_indirect (type $callback_t) drop
            end
          end
          return
        end
        i32.const 901))
  WAT

  test "reentry keeps outer locals, handlers, pools and counters independent" do
    bytes = compile_efflorescence_wat(REENTRY_WAT)
    [{}, {disabled_optimizations: [:all]}, {disabled_optimizations: [:frames]}].each do |mode|
      vm = nil
      nested_metrics = []
      host_error = RuntimeError.new("host failure")
      host = ->(_store, args) do
        case args.fetch(0).value
        when 0
          result = vm.call_unboxed(:inner, [3])
          nested_metrics << vm.metrics
          result
        when 1
          begin
            vm.call_unboxed(:throw, [0])
          rescue Wardite::UncaughtWasmException
            nested_metrics << vm.metrics
            123
          end
        when 2 then raise host_error
        when 3 then vm.call_unboxed(:throw, [0])
        when 4 then raise SystemExit.new(37)
        end
      end
      vm = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), engine: :efflorescence, enable_wasi: false,
        mir_profile: true, import_object: {env: {callback: host}}, **mode).runtime
      [0, 1].each do |indirect|
        assert_equal 14, vm.call_unboxed(:outer, [0, indirect])
        inner = nested_metrics.last
        assert_equal 3, inner.opcode_counts[OP::CALL]
        assert_equal 0, inner.opcode_counts[OP::CALL_HOST]
        assert_equal 0, vm.metrics.opcode_counts[OP::CALL]
        assert_equal 1 - indirect, vm.metrics.opcode_counts[OP::CALL_HOST]
        assert_equal indirect, vm.metrics.opcode_counts[OP::CALL_INDIRECT]
        assert_equal 1, vm.metrics.frames_created
        assert_not_same inner, vm.metrics

        assert_equal 901, vm.call_unboxed(:outer, [1, indirect])
        assert_equal 1, nested_metrics.last.opcode_counts[OP::THROW]
        assert_equal 1, vm.metrics.opcode_counts[OP::THROW]
        assert_equal 2, vm.metrics.frames_created

        error = assert_raise(RuntimeError) { vm.call_unboxed(:outer, [2, indirect]) }
        assert_same host_error, error
        assert_equal 82, vm.call_unboxed(:log, [])
        assert_raise(Wardite::UncaughtWasmException) { vm.call_unboxed(:outer, [3, indirect]) }
        assert_equal 83, vm.call_unboxed(:log, [])
        exit_error = assert_raise(SystemExit) { vm.call_unboxed(:outer, [4, indirect]) }
        assert_equal 37, exit_error.status
        assert_equal 84, vm.call_unboxed(:log, [])
        assert_equal 14, vm.call_unboxed(:outer, [0, indirect])
      end
    end
  end

  test "host memory growth and globals are visible before a trap and isolated by instance" do
    wat = <<~WAT
      (module
        (import "env" "update" (func $update))
        (memory 1 2)
        (global $value (mut i32) (i32.const 0))
        (func $read (export "read") (result i32)
          i32.const 65536 i32.load8_u global.get $value i32.add)
        (func (export "update") (result i32)
          i32.const 0 i32.load8_u call $update call $read i32.add)
        (func (export "fail") call $update unreachable))
    WAT
    update = ->(store, _args) do
      mem = store.memories.fetch(0)
      mem.grow(1)
      mem.data.setbyte(65536, 6)
      store.globals.fetch(0).value = Wardite::I32.new(10)
      nil
    end
    host = {env: {update: update}}
    first, second = Array.new(2) { load_efflorescence(wat, import_object: host).runtime }
    assert_equal 16, first.call_unboxed(:update, [])
    assert_raise_message(/out of bounds/) { second.call_unboxed(:read, []) }
    assert_raise(Wardite::Unreachable) { second.call_unboxed(:fail, []) }
    assert_equal 16, second.call_unboxed(:read, [])
  end

  test "traps bypass Wasm handlers but an indirect callee throw follows its exceptional edge" do
    vm = load_efflorescence(EfflorescenceM3Cases::REFERENCE_WAT).runtime
    assert_equal 14, vm.call_unboxed(:run, [0, 5])
    assert_equal 105, vm.call_unboxed(:run, [1, 5])
    [[2, /type mismatch/], [3, /null/], [4, /out of bounds/]].each do |index, error|
      assert_raise_message(error) { vm.call_unboxed(:run, [index, 5]) }
    end
  end

  test "indirect result is undefined on the exceptional MIR edge" do
    fn = E::Function.new(0, [:i32], [:i32], 0)
    result = fn.allocate_register(0)
    fn.dynamic_sites << E::DynamicCallSite.new(-1, [], [], [:i32], table_index: 0)
    fn.handlers << E::HandlerDescriptor.new([E::CatchTarget.new(-1, [], -1, 4, 0)])
    fn.replace_instructions([[OP::EH_ENTER, 0], [OP::CALL_INDIRECT, result, 0, 0],
      [OP::EH_TRIM, 0], [OP::RETURN, result], [OP::RETURN, result]].map { |a| E::Instruction.new(a) })
    assert_raise_message(/read before definition/) { E::RegisterValidation.new.validate(fn) }
  end
end
