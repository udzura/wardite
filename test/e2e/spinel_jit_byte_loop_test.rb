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
    check_vectors(wat, vectors) do |exits|
      assert_equal 2, exits.size
      latch, guard_exit = exits.fetch(0)
      fault_latch, fault_pc = exits.fetch(1)
      assert_equal latch, fault_latch
      assert_operator guard_exit, :>, latch
      assert_operator fault_pc, :<, latch
    end
  end

  test "fused weighted bytes and division resume at the failing member" do
    wat = <<~WAT
      (module (memory 1) (data (i32.const 9) "ABC")
        (func (export "weight") (param $src i32) (param $dst i32) (param $div i32)
          (param $n i32) (param $bias i32) (result i32)
          loop $again
            local.get $dst
            local.get $bias local.get $src i32.const 1 i32.add i32.load8_u
            i32.const 299 i32.mul i32.add
            i32.const 500 i32.add local.get $div i32.div_u i32.store8
            local.get $dst i32.const 1 i32.add local.set $dst
            local.get $src i32.const 1 i32.add local.set $src
            local.get $div i32.const -1 i32.add local.set $div
            local.get $n i32.const -1 i32.add local.tee $n br_if $again
          end
          local.get $dst)
        (func (export "read") (param i32) (result i32) local.get 0 i32.load8_u))
    WAT
    # The first pixel runs in the VM. Later stores must survive a native side exit.
    vectors = <<~ROWS
      weight 8 20 3 3 0 23
      read 20 245
      read 21 133
      read 22 53
      weight 65534 30 3 2 0 bounds
      read 30 166
      read 31 0
      weight 8 65535 1 2 0 zero
      read 65535 223
      weight 8 65535 3 2 0 bounds
      read 65535 245
      weight 8 40 2 3 0 zero
      read 40 239
      read 41 10
      read 42 0
    ROWS
    check_vectors(wat, vectors) do |exits, code|
      ops = Wardite::Efflorescence::Opcode
      load = code.index(ops::I32_BYTE_MUL_ADD) + 1
      div = code.index(ops::I32_DIV_U_STORE8) + 1
      latch = code.index(ops::BR_IF)
      assert_equal [[latch, latch + 1], [latch, load],
                    [latch, div], [latch, div + 1], [latch, div]], exits
    end
  end

  private

  def check_vectors(wat, vectors)
    Dir.mktmpdir do |dir|
      wasm = File.join(dir, "loop.wasm")
      rows = File.join(dir, "rows.txt")
      worker = File.join(dir, "worker")
      File.binwrite(wasm, compile_efflorescence_wat(wat))
      File.write(rows, vectors)
      vm = File.open(wasm, "rb") do |io|
        Wardite::BinaryLoader.load_from_buffer(io, enable_wasi: false, mir_cache_eager: true).runtime
      end
      code = vm.optimized_ir.functions.first.bytecode.each_slice(Wardite::Efflorescence::Lowerer::WIDTH).map(&:first)
      root = File.expand_path("../..", __dir__)
      output, status = Open3.capture2e(ENV.fetch("SPINEL", "spinel"), "--strict-require", "-O2",
        "-I#{root}/lib", File.join(root, "test/spinel/efflorescence_m4_vectors.rb"), "-o", worker)
      assert_predicate status, :success?, output
      [false, true].each do |jit|
        env = {"WARDITE_MIR_JIT" => jit ? "1" : "0", "WARDITE_TRACE" => "1"}
        output, status = Open3.capture2e(env, worker, wasm, rows)
        assert_predicate status, :success?, output
        exits = output.scan(/backedge (\d+), native exit (\d+) \(store8\)/).map { |pair| pair.map(&:to_i) }
        if jit
          yield exits, code
        else
          assert_empty exits, output
        end
      end
    end
  end

  def invoke(wasm, name, args, jit)
    env = {"WARDITE_MIR_JIT" => jit ? "1" : "0", "WARDITE_TRACE" => "1"}
    Open3.capture2e(env, @binary, "--no-wasi", "--invoke", name, "--", wasm, *args.map(&:to_s))
  end
end
