# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"

class EfflorescenceOperandDecodeTest < Test::Unit::TestCase
  include EfflorescenceHelper
  E = Wardite::Efflorescence

  # Observe actual word reads while keeping every instruction word an Integer.
  class FetchLog < Array
    attr_reader :reads

    def initialize(values)
      super(values)
      @reads = []
    end

    def fetch(index)
      @reads << index
      super
    end
  end

  class InterruptingFetch < Array
    def fetch(_index)
      raise StopIteration, "MIR fetch interrupted"
    end
  end

  def tracked_vm(wat, index: 0, **options)
    vm = load_efflorescence(wat, **options).runtime
    function = vm.ir.function_at(index)
    code = FetchLog.new(function.bytecode)
    function.install_code(code, function.calls)
    [vm, code]
  end

  test "flat execution propagates StopIteration and allows a later invocation" do
    vm = load_efflorescence('(module (func (export "run") (result i32) i32.const 42))').runtime
    function = vm.ir.function_at(0)
    original = function.bytecode
    function.install_code(InterruptingFetch.new(original), function.calls)
    error = assert_raise(StopIteration) { vm.call_unboxed("run", []) }
    assert_equal "MIR fetch interrupted", error.message
    function.install_code(original, function.calls)
    assert_equal 42, vm.call_unboxed("run", [])
  end

  test "RETURN BR and TRAP leave b and c padding unread" do
    vm, code = tracked_vm('(module (func (export "run")))')
    assert_nil vm.call_unboxed("run", [])
    assert_equal [0, 1], code.reads

    vm, code = tracked_vm('(module (func (export "run") (result i32)
      block br 0 end i32.const 7))')
    assert_equal 7, vm.call_unboxed("run", [])
    assert_equal [0, 1, 4, 5], code.reads

    vm, code = tracked_vm('(module (func (export "run") unreachable))')
    assert_raise(Wardite::Unreachable) { vm.call_unboxed("run", []) }
    assert_equal [0, 1], code.reads
  end

  test "COPY and EQZ read b without reading c" do
    vm, code = tracked_vm('(module (func (export "run") (param i32) (result i32)
      local.get 0))', disabled_optimizations: [:copy])
    assert_equal 123, vm.call_unboxed("run", [123])
    assert_equal [0, 1, 2, 4, 5], code.reads

    vm, code = tracked_vm('(module (func (export "run") (param i32) (result i32)
      local.get 0 i32.eqz))')
    assert_equal 1, vm.call_unboxed("run", [0])
    assert_equal [0, 1, 2, 4, 5], code.reads
  end

  test "conditional branches advance exactly once on either edge" do
    [false, true].each do |zero|
      wat = "(module (func (export \"run\") (param i32) (result i32)
        block local.get 0 #{zero ? "i32.eqz" : ""} br_if 0
          i32.const 99 local.set 0
        end local.get 0))"
      vm, code = tracked_vm(wat)
      assert_equal zero ? E::Opcode::BR_IF_ZERO : E::Opcode::BR_IF, code[0]
      taken = zero ? 0 : 1
      assert_equal taken, vm.call_unboxed("run", [taken])
      assert_equal [0, 1, 2, 8, 9], code.reads
      code.reads.clear
      assert_equal 99, vm.call_unboxed("run", [zero ? 1 : 0])
      assert_equal [0, 1, 2, 4, 5, 6, 8, 9], code.reads
    end
  end

  test "CALL resumes at its following instruction and arithmetic still reads c" do
    vm, code = tracked_vm('(module
      (func $id (param i32) (result i32) local.get 0)
      (func (export "run") (param i32) (result i32)
        local.get 0 call $id i32.const 7 i32.add))', index: 1, disabled_optimizations: [:inline])
    assert_equal 12, vm.call_unboxed("run", [5])
    assert_equal (0...10).to_a, code.reads
  end

  test "PROFILE reads all three operands and retains original instruction counts" do
    vm, code = tracked_vm('(module (func (export "run")))', mir_profile: true)
    assert_nil vm.call_unboxed("run", [])
    assert_equal [0, 1, 2, 3, 4, 5], code.reads
    assert_equal 1, vm.metrics.dispatches
  end

  test "complete mix loops keep four-word PCs while decoding fewer words" do
    %w[inline_mix call_mix].each do |name|
      [0, 1, 10].each do |rounds|
        vm = load_efflorescence(File.read(MIX_WAT), disabled_optimizations: [:inline]).runtime
        codes = vm.ir.functions.map do |function|
          code = FetchLog.new(function.bytecode)
          function.install_code(code, function.calls)
          code
        end
        assert_equal reference_mix(rounds, 123), vm.call_unboxed(name, [rounds, 123])
        words_per_round = name == "inline_mix" ? 25 : 31
        assert_equal words_per_round * rounds + 8, codes.sum { |code| code.reads.size }
      end
    end
  end
end
