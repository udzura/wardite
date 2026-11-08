# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"
require_relative "support/efflorescence_m4_cases"

class EfflorescenceM4Test < Test::Unit::TestCase
  include EfflorescenceHelper
  include EfflorescenceM4Cases

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

  test "dead concrete operands still have types" do
    assert_raise(Wardite::Efflorescence::TranslationError) do
      load_efflorescence('(module (func (local i64) unreachable i32.const 1 local.set 0))')
    end
    assert_nothing_raised do
      load_efflorescence('(module (func (local i64) unreachable local.set 0))')
    end
  end
end
