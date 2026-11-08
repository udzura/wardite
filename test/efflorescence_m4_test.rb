# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"
require_relative "support/efflorescence_m4_cases"
require_relative "support/efflorescence_m4_alu_cases"

class EfflorescenceM4Test < Test::Unit::TestCase
  include EfflorescenceHelper
  include EfflorescenceM4Cases
  include EfflorescenceM4ALUCases

  test "mixed control, recursion, local snapshots and frame reuse" do
    [{}, { disabled_optimizations: [:all] }, { disabled_optimizations: [:frames], mir_profile: true }].each do |options|
      runtime = load_efflorescence(CONTROL_WAT, **options).runtime
      minimum = -2**63
      assert_equal minimum, runtime.call_unboxed(:recursive, [4, minimum])
      assert_equal 0, runtime.call_unboxed(:reset, [-1])
      assert_equal minimum, runtime.call_unboxed(:select, [minimum, 1])
      assert_equal 1, runtime.call_unboxed(:select, [minimum, 0])
      assert_equal minimum, runtime.call_unboxed(:branch, [0])
      assert_equal 1, runtime.call_unboxed(:branch, [1])
      assert_equal(-1, runtime.call_unboxed(:identity, [Wardite::I64(-1)]))
      assert_equal(-1, runtime.call_unboxed(:identity, [2**100 - 1]))
      assert_equal 2**64 - 1, runtime.call(:identity, [-1]).value
      assert_raise(Wardite::ArgumentError) { runtime.call(:identity, [Wardite::I32(1)]) }

      branch = runtime.semantic_ir.function_at(runtime.instance.export_section.exports.fetch("branch").index)
      ones = branch.constant_registers.select { |register| branch.initial_value(register) == 1 }
      assert_equal [:i32, :i64], ones.map { |register| branch.register_types.fetch(register) }
    end
  end

  test "all supported ALU instructions match an arbitrary-precision reference" do
    functions, rows = alu_cases
    vm = load_efflorescence("(module #{functions})").runtime
    rows.each do |name, *arguments, expected|
      case expected
      when "zero"
        assert_raise_message("integer divide by zero") { vm.call_unboxed(name, arguments) }
      when "overflow"
        assert_raise(Wardite::IntegerOverflow) { vm.call_unboxed(name, arguments) }
      else
        assert_equal expected, vm.call_unboxed(name, arguments), "#{name} #{arguments.inspect}"
      end
    end
  end

  test "comparison feeds an i32 condition and rejects i64 shift type errors" do
    vm = load_efflorescence(<<~WAT).runtime
      (module (func (export "run") (result i64)
        i64.const -1 i64.const 1 i64.lt_s
        if (result i64) i64.const 42 else i64.const 0 end))
    WAT
    assert_equal 42, vm.call_unboxed("run", [])
    assert_raise(Wardite::Efflorescence::TranslationError) do
      load_efflorescence('(module (func unreachable i64.const 1 i32.const 1 i64.shl drop))')
    end
  end

  test "unused division still traps through a Wasm catch_all" do
    vm = load_efflorescence(<<~WAT).runtime
      (module (func (export "run") (param i64) (result i64)
        block $caught
          try_table (catch_all $caught)
            i64.const 7 local.get 0 i64.div_s drop
          end
          i64.const 1 return
        end
        i64.const -1))
    WAT
    assert_raise_message("integer divide by zero") { vm.call_unboxed("run", [0]) }
    assert_equal 1, vm.call_unboxed("run", [1])
  end

  test "memory, globals and EH preserve signed bits in every execution mode" do
    [{}, { disabled_optimizations: [:all] }, { disabled_optimizations: [:frames], mir_profile: true }].each do |options|
      vm = load_efflorescence(STORE_EH_WAT, **options).runtime
      STORE_EH_ROWS.each do |name, *arguments, expected|
        case expected
        when "bounds"
          data = vm.instance.store.memories.fetch(0).data
          before = data.dup
          assert_raise_message("out of bounds memory access") { vm.call_unboxed(name, arguments) }
          assert_equal before, data
        when "void"
          assert_nil vm.call_unboxed(name, arguments)
        when "uncaught"
          error = assert_raise(Wardite::UncaughtWasmException) { vm.call_unboxed(name, arguments) }
          assert_equal [0xffffffff, arguments.fetch(0), 7], error.payload
          assert_predicate error.payload, :frozen?
          assert_same vm.instance.tags.fetch(0), error.tag
        else
          assert_equal expected, vm.call_unboxed(name, arguments), "#{name} #{arguments.inspect}"
        end
      end
      assert_equal 2**64 - 1, vm.instance.store.globals.fetch(0).value.value
    end
  end

  test "dead concrete operands still have types" do
    assert_raise(Wardite::Efflorescence::TranslationError) do
      load_efflorescence('(module (func (local i64) unreachable i32.const 1 local.set 0))')
    end
    assert_nothing_raised do
      load_efflorescence('(module (func (local i64) unreachable local.set 0))')
    end
  end
end
