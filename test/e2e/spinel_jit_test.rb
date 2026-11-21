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
end
