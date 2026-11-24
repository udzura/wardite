# frozen_string_literal: true

require "test_helper"
require "wardite/efflorescence/spinel_jit/loop_liveness"

class WarditeLoopLivenessTest < Test::Unit::TestCase
  E = Wardite::Efflorescence
  include E::Opcode

  test "fused lookup commits two values and keeps both VM continuations live" do
    # Address temporaries 63 and 64 are unobservable within the fused
    # handler. A VM continuation reading those slots sees their old values.
    code = [
      I64_BYTE_LOOKUP_BR_EQ, 63, 0, 1,
      I32_LOAD8_U, 4, 63, 0,
      I32_ADD, 64, 1, 4,
      I64_LOAD8_U, 5, 64, 0,
      BR_IF_I64_EQ, 5, 28, 2,
      I32_ADD, 6, 4, 63,
      RETURN, 6, 0, 0,
      I32_ADD, 7, 4, 64,
      RETURN, 7, 0, 0
    ]
    function = E::Function.new(0, [], [:i32], 65)
    function.install_code(code, [])
    flow = E::SpinelJIT::LoopLiveness.new(function)
    slots = (0...65).to_a
    assert_equal({0 => [0, 1, 2, 63, 64], 20 => [4, 63], 28 => [4, 64]}, flow.at(slots, [0, 20, 28]))
  end

  test "reject an outside branch into the middle of a candidate path" do
    function = E::Function.new(0, [:i32], [], 0)
    function.install_code([BR_IF, 0, 8, 0, COPY, 0, 0, 0, BR_IF, 0, 4, 0, RETURN, -1, 0, 0], [])
    flow = E::SpinelJIT::LoopLiveness.new(function)
    assert_false flow.single_entry?([false, true, true, false], 4)
  end
end
