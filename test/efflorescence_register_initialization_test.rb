# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"

class EfflorescenceRegisterInitializationTest < Test::Unit::TestCase
  include EfflorescenceHelper
  E = Wardite::Efflorescence
  OP = E::Opcode

  def function(code)
    result = E::Function.new(0, [:i32], [:i32], 0)
    result.allocate_register(0)
    constant = result.allocate_constant(42)
    assert_equal 2, constant
    result.replace_instructions(code.map { |operands| E::Instruction.new(operands) })
    result
  end

  test "only non-parameter locals are cleared on reuse and templates stay independent" do
    fn = E::Function.new(0, [:i32], [:i32], 2)
    temporary = fn.allocate_register(0)
    constant = fn.allocate_constant(42)
    pool = E::FramePool.new(fn, true)
    frame = pool.acquire(-1)
    frame.registers[0] = 123
    frame.registers[1] = 99
    frame.registers[2] = 88
    frame.registers[temporary] = 77
    frame.pc = 12
    pool.release(frame)
    reused = pool.acquire(3)
    assert_same frame, reused
    assert_equal [123, 0, 0, 77, 42], reused.registers
    assert_equal 0, reused.pc
    assert_equal 3, reused.return_register
    assert_equal [0, 0, 0, 0, 42], fn.initial_registers
    other = E::Frame.new(fn, -1)
    assert_equal [0, 0, 0, 0, 42], other.registers
    assert_not_same reused.registers, other.registers
    assert_equal 42, reused.registers[constant]
  end

  test "definite assignment handles both join paths loops and unreachable code" do
    valid = [
      [[OP::BR_IF, 0, 3], [OP::COPY, 1, 2], [OP::BR, 4], [OP::COPY, 1, 0], [OP::RETURN, 1]],
      [[OP::COPY, 1, 0], [OP::BR_IF, 0, 4], [OP::I32_ADD_IMM, 1, 1, 1], [OP::BR, 1], [OP::RETURN, 1]],
      [[OP::BR, 2], [OP::RETURN, 1], [OP::RETURN, 0]],
      [[OP::I32_ADD_IMM, 1, 0, 1], [OP::RETURN, 1]]
    ]
    valid.each { |code| assert_nothing_raised { E::RegisterValidation.new.validate(function(code)) } }
  end

  test "a missing definition on either join edge or on initial loop entry is rejected" do
    invalid = [
      [[OP::RETURN, 1]],
      [[OP::BR_IF, 0, 2], [OP::COPY, 1, 0], [OP::RETURN, 1]],
      # Visit the defined arm first, then lose that fact on a later predecessor.
      [[OP::BR_IF, 0, 3], [OP::COPY, 1, 0], [OP::BR, 4], [OP::BR, 4], [OP::RETURN, 1]],
      [[OP::BR_IF, 0, 3], [OP::COPY, 1, 0], [OP::BR, 0], [OP::RETURN, 1]],
      [[OP::I32_ADD_IMM, 1, 1, 1], [OP::RETURN, 1]]
    ]
    invalid.each do |code|
      error = assert_raise(E::TranslationError) { E::RegisterValidation.new.validate(function(code)) }
      assert_include error.message, "read before definition"
    end
    assert_raise(E::TranslationError) do
      E::RegisterValidation.new.validate(function([[OP::COPY, 2, 0], [OP::RETURN, 2]]))
    end
  end

  test "locals constants branches recursion and trap recovery across execution modes" do
    bytes = compile_efflorescence_wat(RESET_WAT)
    old = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false).runtime
    [[], [:all], [:copy], [:immediate], [:frames]].each do |disabled|
      [false, true].each do |profile|
        vm = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false,
          engine: :efflorescence, disabled_optimizations: disabled, mir_profile: profile).runtime
        3.times do
          [0, 123, 0xffffffff, 0x80000000].each do |seed|
            expected = (seed * 128) % (2**32)
            assert_equal expected, old.call("run", [seed]).value
            assert_equal expected, vm.call_unboxed("run", [seed]), "#{disabled.inspect}, #{profile}"
          end
          [0, 1, 30].each do |depth|
            assert_equal depth * (depth + 1), vm.call_unboxed("recursive", [depth])
          end
          assert_raise(Wardite::Unreachable) { vm.call_unboxed("fail", []) }
          assert_equal 128, vm.call_unboxed("run", [1])
        end
      end
    end
  end

  test "validation supports more registers than a native integer bit mask" do
    expression = (["local.get 0"] + Array.new(100, "i32.const 1 i32.add")).join("\n")
    vm = load_efflorescence("(module (func (export \"run\") (param i32) (result i32) #{expression}))").runtime
    assert_operator vm.ir.functions[0].register_count, :>, 64
    assert_equal 223, vm.call_unboxed("run", [123])
  end

  test "a synchronous reentrant public invocation cannot change the suspended frame" do
    vm = load_efflorescence(RESET_WAT).runtime
    nested = nil
    entered = false
    probe = TracePoint.new(:call) do |event|
      if !entered && event.defined_class == E::Frame && event.method_id == :reset
        entered = true
        nested = vm.call_unboxed("run", [7])
      end
    end
    result = probe.enable { vm.call_unboxed("run", [123]) }
    assert entered
    assert_equal 896, nested
    assert_equal 15744, result
    assert_equal 128, vm.call_unboxed("run", [1])
  ensure
    probe&.disable
  end
end
