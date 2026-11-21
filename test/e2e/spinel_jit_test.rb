# frozen_string_literal: true

require "test_helper"
require_relative "../support/efflorescence_helper"

class WarditeSpinelJITTest < Test::Unit::TestCase
  include EfflorescenceHelper

  test "function JIT executes inline_mix and falls back for unsupported MIR" do
    binary = ENV["WARDITE_SPINEL_BIN"]
    omit "Run bin/test-spinel-jit to test the native executable" unless binary
    omit "AArch64 JIT requires Apple Silicon macOS" unless RUBY_PLATFORM.match?(/arm64-darwin/)
    Dir.mktmpdir do |dir|
      wasm = File.join(dir, "mix.wasm")
      File.binwrite(wasm, compile_efflorescence_wat(File.read(MIX_WAT)))
      env = {"WARDITE_MIR_JIT" => "1", "WARDITE_TRACE" => "1"}
      invoke = [binary, "--no-wasi", "--invoke", "inline_mix"]
      MIX_CASES.each do |rounds, seed|
        output, status = Open3.capture2e(env, *invoke, wasm, rounds.to_s, seed.to_s)
        assert_predicate status, :success?, output
        assert_include output, "MIR JIT function 1: compiled"
        assert_not_include output, "mapping unavailable"
        assert_include output, "return value: #{Wardite::I32(reference_mix(rounds, seed)).inspect}"
      end

      # Removing the immediate/superinstruction passes introduces unsupported
      # opcodes in the very same function. Profiling must count every dispatch.
      [["--mir-disable", "all"], ["--mir-profile"]].each do |options|
        output, status = Open3.capture2e(env, *invoke, *options, wasm, "10", "123")
        assert_predicate status, :success?, output
        assert_include output, "return value: #{Wardite::I32(reference_mix(10, 123)).inspect}"
        assert_not_include output, ": compiled"
        assert_include output, options.include?("--mir-profile") ? "dispatches=" : "function 1: interpreter"
      end
    end
  end

  test "trial division compiles with spills, wide unsigned arithmetic and VM trap replay" do
    binary = ENV["WARDITE_SPINEL_BIN"]
    omit "Run bin/test-spinel-jit to test the native executable" unless binary
    omit "AArch64 JIT requires Apple Silicon macOS" unless RUBY_PLATFORM.match?(/arm64-darwin/)
    wat = File.expand_path("../fixtures/efflorescence/jit_trial_division.wat", __dir__)
    Dir.mktmpdir do |dir|
      wasm = File.join(dir, "trial.wasm")
      File.binwrite(wasm, compile_efflorescence_wat(File.read(wat)))
      env = {"WARDITE_MIR_JIT" => "1", "WARDITE_TRACE" => "1"}
      cases = [
        ["odd_prime", [9], 0], ["odd_prime", [97], 1],
        ["odd_prime", [4294967291], 1], ["wide", [65536], 0], ["wide", [0xffffffff], 1],
        # Successful values may also equal any of the native status codes.
        ["remainder", [3, 3], 0], ["remainder", [4, 3], 1], ["remainder", [5, 3], 2],
        ["remainder", [0xffffffff, 65536], 65535],
        ["remainder", [0xfffffffe, 0xffffffff], 0xfffffffe]
      ]
      cases.each do |name, args, expected|
        output, status = Open3.capture2e(env, binary, "--no-wasi", "--invoke", name, wasm, *args.map(&:to_s))
        assert_predicate status, :success?, output
        assert_match(/MIR JIT function \d+: compiled/, output)
        assert_not_include output, "bailout"
        assert_not_include output, "mapping unavailable"
        assert_include output, "return value: #{Wardite::I32(expected).inspect}"
      end
      [["odd_prime", ["0"]], ["remainder", ["1", "0"]]].each do |name, args|
        output, status = Open3.capture2e(env, binary, "--no-wasi", "--invoke", name, wasm, *args)
        assert_false status.success?, output
        assert_include output, "interpreter bailout"
        assert_include output, "integer divide by zero"
      end
    end
  end
end
