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

  test "side exits and trapping stores preserve the prefix of memory writes" do
    wat = <<~WAT
      (module
        (memory 1)
        (func (export "mark") (param $ptr i32) (param $count i32) (param $stop i32) (result i32)
          block $done
            loop $again
              local.get $ptr local.get $stop i32.ge_u br_if $done
              i32.const 0 i32.const 0 i32.load8_u i32.const 1 i32.add i32.store8
              local.get $ptr i32.const 427 i32.store8 offset=1
              local.get $ptr i32.const 1 i32.add local.set $ptr
              local.get $count i32.const -1 i32.add local.tee $count br_if $again
            end
          end
          i32.const 0 i32.load8_u)
        (func (export "read") (param i32) (result i32) local.get 0 i32.load8_u))
    WAT
    # Each call observes the same instance. Byte zero counts attempted stores,
    # including the increment immediately before the store that traps.
    vectors = <<~ROWS
      mark 5 6 8 3
      read 8 171
      read 9 0
      mark 65532 4 4294967295 bounds
      read 0 7
      read 65535 171
    ROWS
    Dir.mktmpdir do |dir|
      wasm = File.join(dir, "mark.wasm")
      rows = File.join(dir, "rows.txt")
      worker = File.join(dir, "worker")
      File.binwrite(wasm, compile_efflorescence_wat(wat))
      File.write(rows, vectors)
      root = File.expand_path("../..", __dir__)
      output, status = Open3.capture2e(ENV.fetch("SPINEL", "spinel"), "--strict-require", "-O2",
        "-I#{root}/lib", File.join(root, "test/spinel/efflorescence_m4_vectors.rb"), "-o", worker)
      assert_predicate status, :success?, output
      [false, true].each do |jit|
        env = {"WARDITE_MIR_JIT" => jit ? "1" : "0", "WARDITE_TRACE" => "1"}
        output, status = Open3.capture2e(env, worker, wasm, rows)
        assert_predicate status, :success?, output
        exits = output.scan(/backedge (\d+), native exit (\d+) \(store8\)/)
        assert_equal jit ? 2 : 0, exits.size, output
        if jit
          latch, guard_exit = exits.fetch(0).map(&:to_i)
          fault_latch, fault_pc = exits.fetch(1).map(&:to_i)
          assert_equal latch, fault_latch
          assert_operator guard_exit, :>, latch
          assert_operator fault_pc, :<, latch
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
