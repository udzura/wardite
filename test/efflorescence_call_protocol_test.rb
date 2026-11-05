# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"

class EfflorescenceCallProtocolTest < Test::Unit::TestCase
  include EfflorescenceHelper
  E = Wardite::Efflorescence

  test "flat calls encode a single source including slot zero or the generic sentinel" do
    [[], [:all], [:copy], [:immediate]].each do |disabled|
      # Disabling all selects semantic execution; lower a copy to inspect it.
      vm = load_efflorescence(CALL_PROTOCOL_WAT, disabled_optimizations: disabled + [:inline]).runtime
      ir = vm.optimized_ir.copy
      E::Lowerer.new.compile(ir)
      counts = []
      ir.functions.each do |function|
        function.instructions.each_with_index do |instruction, pc|
          next unless instruction[0] == E::Opcode::CALL
          arguments = instruction.operands.drop(3)
          counts << arguments.size
          encoded = function.bytecode[pc * 4 + 3]
          assert_equal arguments.size == 1 ? arguments[0] : -1, encoded
          site = function.call_site(function.bytecode[pc * 4 + 2])
          assert_equal site.callee.index, site.pool_index
          assert_equal arguments, site.arguments
        end
      end
      assert_include counts, 0
      assert_include counts, 1
      assert_include counts, 2
      assert_include counts, 3
    end
    fn = load_efflorescence('(module (func $id (param i32) (result i32) local.get 0)
      (func (export "run") (param i32) (result i32) local.get 0 call $id))',
      disabled_optimizations: [:inline]).runtime.ir.functions[1]
    call_pc = fn.instructions.index { |instruction| instruction[0] == E::Opcode::CALL }
    assert_not_nil call_pc
    assert_equal 0, fn.bytecode[call_pc * 4 + 3]
  end

  test "mixed arities void calls argument snapshots and mutual recursion agree with the stack VM" do
    bytes = compile_efflorescence_wat(CALL_PROTOCOL_WAT)
    old = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false).runtime
    [[], [:all], [:copy], [:immediate], [:frames], [:inline]].each do |disabled|
      [false, true].each do |profile|
        vm = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false,
          engine: :efflorescence, disabled_optimizations: disabled, mir_profile: profile).runtime
        2.times do
          [0, 1, 123, 0xffffffff, 0x80000000].each do |x|
            expected = ((x + 18) % (2**32)) ^ ((9 * x - 1) % (2**32))
            assert_equal expected, old.call("run", [x]).value
            assert_equal expected, vm.call_unboxed("run", [x])
            assert_equal 0xffffffff, vm.call_unboxed("alias", [x])
          end
          [0, 1, 30, 50].each do |depth|
            assert_equal depth * (depth + 1) / 2 + 27, vm.call_unboxed("mutual", [depth])
          end
        end
      end
    end
  end
end
