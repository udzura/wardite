# frozen_string_literal: true

require "test_helper"
require_relative "../support/efflorescence_helper"

class WarditeSpinelJITByteLoopTest < Test::Unit::TestCase
  include EfflorescenceHelper

  def setup
    @binary = ENV["WARDITE_SPINEL_BIN"]
    omit "Run bin/test-spinel-jit on Apple Silicon" unless @binary && RUBY_PLATFORM.match?(/arm64-darwin/)
  end

  test "checked byte-load loop uses current memory and resumes on an out-of-bounds load" do
    wat = <<~WAT
      (module
        (memory 1 2)
        (func $scan (export "scan") (param $ptr i32) (param $n i32) (param $stride i32) (result i32) (local $sum i32)
          loop $loop
            local.get $sum local.get $ptr i32.load8_u offset=3 i32.eqz i32.add local.set $sum
            local.get $ptr local.get $stride i32.add local.set $ptr
            local.get $n i32.const -1 i32.add local.tee $n br_if $loop
          end
          local.get $sum)
        (func (export "grow_scan") (result i32)
          i32.const 1 memory.grow drop
          i32.const 65536 i32.const 8 i32.const 1 call $scan))
    WAT
    Dir.mktmpdir do |dir|
      wasm = File.join(dir, "scan.wasm")
      File.binwrite(wasm, compile_efflorescence_wat(wat))
      [["grow_scan", [], "I32(8)"], ["scan", [65532, 2, 1], nil],
       ["scan", [0, 2, 0xfffffffe], nil]].each do |name, args, value|
        [false, true].each do |jit|
          output, status = invoke(wasm, name, args, jit)
          assert_equal !!value, status.success?, output
          assert_include output, value ? "return value: #{value}" : "out of bounds memory access"
          assert_equal jit, output.include?("MIR JIT byte loop"), output
        end
      end
    end
  end

  private

  def invoke(wasm, name, args, jit)
    env = {"WARDITE_MIR_JIT" => jit ? "1" : "0", "WARDITE_TRACE" => "1"}
    Open3.capture2e(env, @binary, "--no-wasi", "--invoke", name, "--", wasm, *args.map(&:to_s))
  end
end
