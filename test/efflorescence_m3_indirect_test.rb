# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"
require_relative "support/efflorescence_m3_cases"

class EfflorescenceM3IndirectTest < Test::Unit::TestCase
  include EfflorescenceHelper

  test "indirect calls use live table identity and structural signatures" do
    bytes = compile_efflorescence_wat(EfflorescenceM3Cases::INDIRECT_WAT)
    [{}, {disabled_optimizations: [:all]}, {disabled_optimizations: [:frames]}, {mir_profile: true}].each do |mode|
      calls = []
      sum = ->(_store, args) { calls << args.map(&:value); args[0].value + args[1].value }
      wrong = ->(_store, _args) { flunk "mismatched host was invoked" }
      host = {env: {sum: sum, wrong: wrong}}
      inst = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false, engine: :efflorescence,
        import_object: host, **mode)
      vm = inst.runtime
      assert_equal [[1, 2]], calls
      assert_equal 9, vm.call_unboxed(:run, [0, 17, 8])
      if mode[:mir_profile]
        assert_equal [0, 1, 4, 3], dynamic_metrics(vm)
      end
      assert_equal 25, vm.call_unboxed(:run, [1, 17, 8])
      if mode[:mir_profile]
        assert_equal [1, 1, 4, 2], dynamic_metrics(vm)
        assert_include vm.metrics.report, "host_calls=1 indirect_calls=1"
      end
      assert_equal 9, vm.call_unboxed(:run, [5, 17, 8])
      assert_equal [[1, 2], [17, 8]], calls
      assert_equal 6, vm.call_unboxed(:effects, [])
      [[2, /type mismatch/], [3, /type mismatch/], [4, /null/], [6, /out of bounds/], [-1, /out of bounds/]].each do |index, error|
        assert_raise_message(error) { vm.call_unboxed(:run, [index, 17, 8]) }
      end
      assert_equal 16, vm.call_unboxed(:effects, [])
      table = inst.store.tables.fetch(0)
      table.refs[0] = inst.store.funcs.fetch(0)
      assert_equal 25, vm.call_unboxed(:run, [0, 17, 8])
      assert_equal [[1, 2], [17, 8], [17, 8]], calls
      table.refs[0] = inst.store.funcs.fetch(0).clone
      assert_raise_message(/unknown function reference/) { vm.call_unboxed(:run, [0, 17, 8]) }
      assert_equal [0, 1, 3, 2], dynamic_metrics(vm) if mode[:mir_profile]

      semantic = vm.semantic_ir.functions.last.dynamic_sites.first
      lowered = vm.ir.functions.last.dynamic_sites.first
      assert_equal semantic.arguments, lowered.arguments
      assert_not_same semantic.arguments, lowered.arguments
      assert_include vm.dump_mir, "CALL_INDIRECT"
      assert_include vm.dump_mir, "table=0 [:i32, :i32] -> [:i32]"
    end
  end

  def dynamic_metrics(vm)
    metrics = vm.metrics
    [metrics.host_calls, metrics.indirect_calls, metrics.function_entries, metrics.frames_created]
  end

  test "unreachable indirect calls still validate table and type immediates" do
    [
      '(module (type $t (func)) (func unreachable call_indirect (type $t)))',
      '(module (type $t (func)) (table 1 externref) (func unreachable call_indirect (type $t)))',
      '(module (table 1 funcref) (func unreachable call_indirect (type 50)))',
      '(module (type $t (func (result f64 i32))) (table 1 funcref) (func unreachable call_indirect (type $t)))',
      '(module (type $t (func)) (table 1 funcref) (table 1 funcref) (func unreachable call_indirect 1 (type $t)))'
    ].each do |wat|
      assert_raise_kind_of(Wardite::LoadError) { load_efflorescence(wat) }
    end
  end

  test "dynamic call operands participate in register analysis and remapping" do
    mir = Wardite::Efflorescence
    function = mir::Function.new(0, [:i32, :i32], [:i32], 0)
    result = function.allocate_register(0)
    function.dynamic_sites << mir::DynamicCallSite.new(-1, [0], [:i32], [:i32], table_index: 0)
    function.replace_instructions([
      mir::Instruction.new([mir::Opcode::CALL_INDIRECT, result, 0, 1]),
      mir::Instruction.new([mir::Opcode::RETURN, result])
    ])
    copied = function.copy
    copied.replace_register_references!([1, 0, 2])
    assert_equal [1, 0], function.reads(function.instructions.first)
    assert_equal [0, 1], copied.reads(copied.instructions.first)
    assert_nothing_raised { mir::RegisterValidation.new.validate(copied) }
    copied.dynamic_sites.first.arguments << 0
    assert_raise_message(/invalid MIR dynamic call signature/) { mir::RegisterValidation.new.validate(copied) }
  end

  test "active elements reject invalid indices, offsets and range even with no call" do
    [
      '(module (table 1 funcref) (elem (i32.const 0) func 0))',
      '(module (table 1 funcref) (func $f) (elem (i32.const -1) func $f))',
      '(module (table 1 funcref) (func $f) (elem (i32.const 1) func $f))',
      '(module (table 1 funcref) (elem (i32.const 2) func))'
    ].each do |wat|
      assert_raise(Wardite::LoadError) { load_efflorescence(wat) }
    end
  end
end
