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
          i32.const 0 i32.const 4 i32.const 1 call $scan drop
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
          entries = name == "grow_scan" ? 2 : 1
          assert_equal jit ? entries : 0, output.scan("MIR JIT byte loop function").size, output
          assert_equal jit ? 1 : 0, output.scan("MIR JIT mapped byte-loop page").size, output
          assert_equal jit ? 1 : 0, output.scan("MIR JIT released byte-loop page").size, output
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

  test "hot lookup loops preserve call arguments and store prefixes at VM exits" do
    wat = <<~'WAT'
      (module
       (memory 1 2)
       (data (i32.const 1025) "\01") (data (i32.const 4096) "B\ff")
       (func $report (param i32 i32) (result i32) local.get 0 i32.const 8 i32.shl local.get 1 i32.or)
       (func $scan (export "scan") (param $src i32) (param $table i32) (param $dst i32) (param $n i32) (result i32)
         (local $byte i32) (local $value i64)
         block $bad
           loop $again
             local.get $table local.get $src i32.const 1 i32.add i32.load8_u local.tee $byte
             i32.add i64.load8_u local.tee $value i64.const 255 i64.eq br_if $bad
             local.get $dst local.get $value i64.store32 offset=1
             local.get $dst i32.const 4 i32.add local.set $dst
             local.get $src i32.const 1 i32.add local.set $src
             local.get $n i32.const -1 i32.add local.tee $n br_if $again
           end
           local.get $dst return
         end
         local.get $src local.get $byte call $report)
       (func (export "grow") (result i32) i32.const 1 memory.grow)
       (func (export "byte") (param i32) (result i32) local.get 0 i32.load8_u))
    WAT
    # The sentinel is in the first native iteration. The exit calls $report
    # with the updated pointer and byte via the flat call-site argument table.
    vectors = <<~ROWS
      scan 0 4096 10000 1030 262145
      byte 14093 66
      byte 14097 0
      scan 2048 4096 14001 3 14013
      scan 65532 4096 15000 5 bounds
      byte 15009 66
      byte 15013 0
      scan 1023 65535 16000 3 bounds
      scan 2048 4096 65530 3 bounds
      byte 65531 66
      byte 65535 0
      grow 1
      scan 65534 4096 80000 3 80012
      byte 80009 66
    ROWS
    with_vector_traces(wat, vectors) do |jit, output, _code|
      exits = output.scan(/lookup loop function 1: backedge 9, native exit (\d+), iterations (\d+)/)
      assert_equal jit ? [%w[11 1], %w[10 2], %w[0 3], %w[0 1], %w[5 1], %w[10 2]] : [], exits, output
    end
  end

  test "encoder lookup loops guard wide loads and byte stores at their original PCs" do
    wat = <<~'WAT'
      (module (memory 1)
        (data (i32.const 8192) "A") (data (i32.const 8255) "Z") (data (i32.const 65535) "\ff")
        (func (export "map") (param $src i32) (param $step i32) (param $table i32)
          (param $dst i32) (param $count i32) (result i32)
          loop $again
            local.get $dst local.get $table
            local.get $src i64.load offset=1 align=1 i64.const 56 i64.shr_u i32.wrap_i64
            i32.const 63 i32.and i32.add i32.load8_u i32.store8 offset=1
            local.get $dst i32.const 1 i32.add local.set $dst
            local.get $src local.get $step i32.add local.set $src
            local.get $count i32.const -1 i32.add local.tee $count br_if $again
          end
          local.get $dst)
        (func (export "read") (param i32) (result i32) local.get 0 i32.load8_u))
    WAT
    vectors = <<~ROWS
      map 0 0 8192 10000 1028 11028
      map 65525 1 8192 20000 4 bounds
      read 20002 65
      read 20003 90
      read 20004 0
      map 65526 1 65500 21000 2 bounds
      read 21002 0
      map 0 4294967295 8192 22000 2 bounds
      read 22001 65
      read 22002 0
      map 0 0 8192 65533 3 bounds
      read 65535 65
    ROWS
    with_vector_traces(wat, vectors) do |jit, output, code|
      ops = Wardite::Efflorescence::Opcode
      assert_include code, ops::I32_EXTRACT_I64
      table = code.index(ops::I32_TABLE_STORE8)
      assert_not_nil table
      load = code.index(ops::I64_LOAD)
      latch = code.index(ops::BR_IF)
      exits = output.scan(/lookup loop function 0: backedge \d+, native exit (\d+), iterations (\d+)/)
      expected = [[latch + 1, 4], [load, 3], [table + 1, 1], [load, 1], [table + 2, 2]]
      assert_equal jit ? expected : [], exits.map { |row| row.map(&:to_i) }, output
    end
  end

  test "byte-add loops preserve overlapping writes and resume at a trapping member" do
    wat = <<~'WAT'
      (module (memory 1) (data (i32.const 65535) "\ff")
        (func (export "add") (param $src i32) (param $dst i32) (param $count i32) (result i32)
          loop $again
            local.get $dst local.get $src i32.load8_u local.get $count i32.add i32.store8
            local.get $dst i32.const 1 i32.add local.set $dst
            local.get $src i32.const 1 i32.add local.set $src
            local.get $count i32.const -1 i32.add local.tee $count br_if $again
          end
          local.get $dst)
        (func (export "read") (param i32) (result i32) local.get 0 i32.load8_u))
    WAT
    # src and dst overlap on the first call. Native iterations consume the
    # bytes stored by previous VM and native iterations, including overflow.
    vectors = <<~ROWS
      add 0 1 1028 1029
      read 1028 10
      add 65534 2000 3 bounds
      read 2000 3
      read 2001 1
      read 2002 0
      add 3000 65534 3 bounds
      read 65534 3
      read 65535 2
    ROWS
    with_vector_traces(wat, vectors) do |jit, output, code|
      ops = Wardite::Efflorescence::Opcode
      head = code.index(ops::I32_BYTE_ADD_STORE)
      assert_not_nil head
      latch = code.index(ops::BR_IF)
      exits = output.scan(/byte-add loop function 0: backedge \d+, native exit (\d+)/).flatten.map(&:to_i)
      assert_equal jit ? [latch + 1, head, head + 2] : [], exits, output
    end
  end

  private

  def check_vectors(wat, vectors)
    with_vector_traces(wat, vectors) do |jit, output, code|
      exits = output.scan(/backedge (\d+), native exit (\d+) \(store8\)/).map { |pair| pair.map(&:to_i) }
      if jit
        yield exits, code
      else
        assert_empty exits, output
      end
    end
  end

  def with_vector_traces(wat, vectors)
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
        yield jit, output, code
      end
    end
  end

  def invoke(wasm, name, args, jit)
    env = {"WARDITE_MIR_JIT" => jit ? "1" : "0", "WARDITE_TRACE" => "1"}
    Open3.capture2e(env, @binary, "--no-wasi", "--invoke", name, "--", wasm, *args.map(&:to_s))
  end
end
