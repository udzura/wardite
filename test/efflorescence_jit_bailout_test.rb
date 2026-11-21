# frozen_string_literal: true

require "test_helper"
require "wardite/efflorescence/spinel_jit/aarch64"

class EfflorescenceJITBailoutTest < Test::Unit::TestCase
  include Wardite::Efflorescence

  def compile(words)
    function = Function.new(0, [:i32], [:i32], 0)
    function.install_code(words + [Opcode::RETURN, 0, 0, 0], [])
    SpinelJIT::AArch64.new.compile(function)
  end

  test "only a side-effect-free prefix can precede a replayed call" do
    cold_call = [Opcode::CALL, -1, 0, 0, Opcode::TRAP, 0, 0, 0]
    assert_not_nil compile(cold_call)
    assert_nil compile([Opcode::GLOBAL_SET, 0, 0, 0] + cold_call)
    assert_nil compile([Opcode::I32_STORE, 0, 0, 0] + cold_call)
    assert_nil compile([Opcode::CALL, -1, 0, 0])
  end

  test "MIR branches cannot target the private bailout label or a partial instruction" do
    [Opcode::BR_IF, Opcode::BR_IF_ZERO].each do |opcode|
      assert_not_nil compile([opcode, 0, 4, 0])
      [-1, 1, 8].each { |target| assert_nil compile([opcode, 0, target, 0]) }
    end
  end
end
