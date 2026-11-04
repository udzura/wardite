# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"

class EfflorescenceCallAritiesTest < Test::Unit::TestCase
  include EfflorescenceHelper
  E = Wardite::Efflorescence
  INCREMENTS = {"empty_loop" => 0, "call_zero" => 7, "call_one" => 0,
    "call_two" => 1, "call_three" => 3, "call_four" => 6}.freeze

  class ArgumentLog < Array
    attr_accessor :fetches

    def initialize(values)
      super(values)
      @fetches = 0
    end

    def fetch(index)
      @fetches += 1
      super
    end
  end

  test "all transfer arities agree with the stack VM and independent references across execution modes" do
    bytes = compile_efflorescence_wat(File.read(ARITY_WAT))
    old = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false).runtime
    [[], [:inline], [:inline, :flat], [:inline, :frames], [:inline, :copy], [:all]].each do |disabled|
      [false, true].each do |profile|
        vm = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false,
          engine: :efflorescence, disabled_optimizations: disabled, mir_profile: profile).runtime
        INCREMENTS.each do |name, step|
          [[0, 0], [0, 123], [1, 0xffffffff], [10, 123], [1000, 0xffffffff]].each do |rounds, seed|
            expected = (seed + step * rounds) % (2**32)
            assert_equal expected, old.call(name, [rounds, seed]).value
            assert_equal expected, vm.call_unboxed(name, [rounds, seed]), "#{disabled.inspect}, profile=#{profile}, #{name}"
          end
        end
      end
    end
  end

  test "argument sources remain stable across repeated transfers and zero calls read no sources" do
    INCREMENTS.each_key do |name|
      next if name == "empty_loop"
      vm = load_efflorescence(File.read(ARITY_WAT), disabled_optimizations: [:inline]).runtime
      logs = []
      vm.ir.functions.each do |fn|
        calls = fn.calls.map do |site|
          arguments = ArgumentLog.new(site.arguments)
          logs << arguments
          replacement = E::CallSite.new(site.callee, arguments)
          arguments.fetches = 0
          replacement
        end
        fn.install_code(fn.bytecode, calls)
      end
      transfers = 0
      trace = TracePoint.new(:call) do |event|
        transfers += 1 if event.defined_class == E::CallSite && event.method_id == :copy_arguments
      end
      2.times do
        value = trace.enable { vm.call_unboxed(name, [10, 123]) }
        assert_equal 123 + INCREMENTS.fetch(name) * 10, value
      end
      assert_equal name == "call_one" ? 0 : 20, transfers
      arity = %w[call_zero call_one call_two call_three call_four].index(name)
      assert_equal name == "call_one" ? 0 : 20 * arity, logs.sum(&:fetches)
    ensure
      trace&.disable
    end
  end

  test "multi-argument recursion preserves active callers and repeated or permuted sources" do
    bytes = compile_efflorescence_wat(ARITY_EDGE_WAT)
    old = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false).runtime
    [[], [:inline], [:inline, :flat], [:inline, :frames], [:all]].each do |disabled|
      [false, true].each do |profile|
        vm = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false,
          engine: :efflorescence, disabled_optimizations: disabled, mir_profile: profile).runtime
        2.times do
          [0, 1, 50].product([0, 123, 0xffffffff]).each do |n, seed|
            {"two" => 1, "three" => 3}.each do |name, step|
              expected = (seed + step * n + n * (n + 1) / 2) % (2**32)
              assert_equal expected, old.call(name, [n, seed]).value
              assert_equal expected, vm.call_unboxed(name, [n, seed])
            end
          end
          assert_equal 313, vm.call_unboxed("permuted", [17, 23, 31])
          assert_equal 0xfffffff7, vm.call_unboxed("duplicate", [0xffffffff])
        end
      end
    end
  end
end
