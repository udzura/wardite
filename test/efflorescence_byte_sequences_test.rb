# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"

class EfflorescenceByteSequencesTest < Test::Unit::TestCase
  include EfflorescenceHelper
  E = Wardite::Efflorescence
  OP = E::Opcode

  def check_sequence(body, opcode, arguments, expected, forwarded_reads: 2)
    wasm = compile_efflorescence_wat(<<~WAT)
      (module (memory 1) (data (i32.const 8) "Q")
        (func (export "run") (param i32 i32 i32) (result i32) #{body})
        (func (export "read") (param i32) (result i32) local.get 0 i32.load8_u))
    WAT
    reference = Wardite.new(buffer: StringIO.new(wasm), enable_wasi: false, mir_profile: true,
      disabled_optimizations: [:superinstruction]).runtime
    assert_equal expected, reference.call_unboxed(:run, arguments)
    Dir.mktmpdir do |dir|
      [{}, {mir_cache_eager: true}, {mir_profile: true}, {disabled_optimizations: [:superinstruction]},
       {mir_cache: dir}, {mir_cache: dir}].each do |options|
        vm = Wardite.new(buffer: StringIO.new(wasm), enable_wasi: false, **options).runtime
        assert_equal expected, vm.call_unboxed(:run, arguments), options.inspect
        fn = vm.ir.function_at(0)
        codes = fn.bytecode.each_slice(E::Lowerer::WIDTH).map(&:first)
        assert_equal !options.key?(:disabled_optimizations), codes.include?(opcode), options.inspect
        if options[:mir_profile]
          assert_include vm.metrics.opcode_report, "opcode #{OP::NAMES.fetch(opcode)} 1"
          assert_equal reference.metrics.dispatches - 3, vm.metrics.dispatches
          assert_equal reference.metrics.register_writes, vm.metrics.register_writes
          assert_equal reference.metrics.register_reads - forwarded_reads, vm.metrics.register_reads
        end
        yield vm if block_given?
      end
    end
  end

  test "cache validation requires all operands of the fused byte sequence" do
    require "wardite/efflorescence/mir_cache"
    fn = E::Function.new(0, [:i32] * 7, [], 0)
    code = [OP::I32_TABLE_STORE8, 1, 2, 3, OP::I32_LOAD8_U, 4, 1, 0,
      OP::I32_STORE8, 4, 5, 0, OP::I32_ADD_IMM, 6, 5, 1, OP::RETURN, -1, 0, 0]
    decoder = E::MIRCache::Decoder.allocate
    decoder.instance_variable_set(:@has_memory, true)
    fn.install_code(code, [])
    assert_nothing_raised { decoder.send(:check_code, fn) }
    [code.take(12), code.dup.tap { |c| c[8] = OP::COPY },
     code.dup.tap { |c| c[9] = 5 }, code.dup.tap { |c| c[10] = 7 }].each do |invalid|
      fn.install_code(invalid, [])
      assert_raise(E::MIRCache::Invalid) { decoder.send(:check_code, fn) }
    end
  end

  test "computed byte lookup followed by a store preserves offsets and i32 wrapping" do
    check_sequence(<<~WAT, OP::I32_TABLE_STORE8, [0xffffffff, 7, 17], 18) do |vm|
      local.get 2 local.get 0 local.get 1 i32.add i32.load8_u offset=2 i32.store8 offset=3
      local.get 2 i32.const 1 i32.add
    WAT
      assert_equal 81, vm.call_unboxed(:read, [20])
    end
  end

  test "byte lookup forwards the unsigned byte and wraps the table address" do
    check_sequence(<<~WAT, OP::I64_BYTE_LOOKUP, [6, 0xffffffb7, 0], 81, forwarded_reads: 3)
      local.get 1 local.get 0 i32.const 2 i32.add i32.load8_u i32.add i64.load8_u i32.wrap_i64
    WAT
  end

  test "lookup branch preserves both results, wrapping, traps and memory growth" do
    wasm = compile_efflorescence_wat(<<~WAT)
      (module (memory 1 2) (data (i32.const 8) "A") (data (i32.const 165) "Q")
        (func (export "probe") (param $src i32) (param $table i32) (param $key i64)
          (result i32) (local $byte i32)
          (block $found
            local.get $table local.get $src i32.const 1 i32.add
            i32.load8_u local.tee $byte i32.add i64.load8_u
            local.get $key i64.eq br_if $found i32.const -1 return)
          local.get $byte)
        (func (export "grow") (result i32) i32.const 1 memory.grow))
    WAT
    Dir.mktmpdir do |dir|
      if (binary = ENV["WARDITE_SPINEL_BIN"])
        path = File.join(dir, "lookup.wasm")
        File.binwrite(path, wasm)
        [[7, 100, 65], [7, 0xffffffc7, 65], [65535, 0, nil], [7, 65535, nil]].each do |src, table, expected|
          key = table == 100 ? 81 : 65
          _, err, status = Open3.capture3(binary, "--no-wasi", "--invoke", "probe", "--", path,
            src.to_s, table.to_s, key.to_s)
          assert_equal !expected.nil?, status.success?, err
          assert_include err, expected ? "I32(#{expected})" : "out of bounds memory access"
        end
      end
      [{disabled_optimizations: [:superinstruction]}, {mir_cache: dir}, {mir_cache: dir},
       {mir_profile: true}].each do |opts|
        vm = Wardite.new(buffer: StringIO.new(wasm), enable_wasi: false, **opts).runtime
        assert_equal 65, vm.call_unboxed(:probe, [7, 100, 81])
        assert_equal 0xffffffff, vm.call_unboxed(:probe, [7, 100, 80])
        assert_equal 65, vm.call_unboxed(:probe, [7, 0xffffffc7, 65])
        assert_equal 0, vm.call_unboxed(:probe, [0xffffffff, 8, 65])
        [[65535, 0, 0], [7, 65535, 0]].each do |args|
          error = assert_raise(Wardite::EvalError) { vm.call_unboxed(:probe, args) }
          assert_equal "out of bounds memory access", error.message
        end
        assert_equal 1, vm.call_unboxed(:grow, [])
        assert_equal 0, vm.call_unboxed(:probe, [65535, 8, 65])
        ops = vm.ir.function_at(0).bytecode.each_slice(E::Lowerer::WIDTH).map(&:first)
        assert_equal !opts.key?(:disabled_optimizations), ops.include?(OP::I64_BYTE_LOOKUP_BR_EQ)
      end
    end
  end

  test "lookup branch requires dead address slots and a single entry" do
    words = [[OP::I32_ADD_IMM, 4, 0, 1], [OP::I32_LOAD8_U, 3, 4, 0],
      [OP::I32_ADD, 5, 1, 3], [OP::I64_LOAD8_U, 6, 5, 0], [OP::BR_IF_I64_EQ, 6, 5, 2],
      [OP::RETURN, 3]]
    [words, words + [[OP::RETURN, 4]], words + [[OP::RETURN, 5]], words + [[OP::BR, 4]],
     words.map.with_index { |w, i| i == 2 ? [OP::I32_ADD, 5, 3, 3] : w }].each_with_index do |body, i|
      fn = E::Function.new(0, [:i32, :i32, :i64], [:i32], 1)
      3.times { fn.allocate_register(0) }
      fn.replace_instructions(body.map { |w| E::Instruction.new(w.dup) })
      E::ByteSequences.fuse(fn)
      assert_equal i.zero? ? OP::I64_BYTE_LOOKUP_BR_EQ : OP::I64_BYTE_LOOKUP, fn.instructions[0][0]
    end
  end

  test "weighted bytes preserve the low word of the product and sum" do
    check_sequence(<<~WAT, OP::I32_BYTE_MUL_ADD, [6, 90, 0], 9, forwarded_reads: 3)
      local.get 1 local.get 0 i32.const 2 i32.add i32.load8_u i32.const -1 i32.mul i32.add
    WAT
  end

  test "byte reconstruction truncates the stored sum and preserves address advancement" do
    check_sequence(<<~WAT, OP::I32_BYTE_ADD_STORE, [8, 200, 20], 21) do |vm|
      local.get 2 local.get 0 i32.load8_u local.get 1 i32.add i32.store8
      local.get 2 i32.const 1 i32.add
    WAT
      assert_equal 25, vm.call_unboxed(:read, [20])
    end
  end

  test "byte division stores wrap before division and preserve trap order" do
    body = <<~WAT
      local.get 2 local.get 0 i32.const 5 i32.add local.get 1 i32.div_u i32.store8 offset=3
      local.get 2 i32.const 1 i32.add
    WAT
    check_sequence(body, OP::I32_DIV_U_STORE8, [0xfffffffe, 2, 17], 18) do |vm|
      assert_equal 1, vm.call_unboxed(:read, [20])
      assert_equal 18, vm.call_unboxed(:run, [512, 2, 17])
      assert_equal 2, vm.call_unboxed(:read, [20])
      zero = assert_raise(Wardite::EvalError) { vm.call_unboxed(:run, [512, 0, 0xffffffff]) }
      assert_equal "integer divide by zero", zero.message
      bounds = assert_raise(Wardite::EvalError) { vm.call_unboxed(:run, [512, 2, 0xffffffff]) }
      assert_equal "out of bounds memory access", bounds.message
    end
  end

  test "a branch into the sequence keeps individual dispatches" do
    fn = E::Function.new(0, [], [], 0)
    fn.replace_instructions([
      [OP::BR, 2], [OP::I32_ADD, 1, 2, 3], [OP::I32_LOAD8_U, 4, 1, 0],
      [OP::I32_STORE8, 4, 5, 0], [OP::I32_ADD_IMM, 6, 5, 1], [OP::RETURN, -1]
    ].map { |words| E::Instruction.new(words) })
    E::ByteSequences.fuse(fn)
    assert_equal OP::I32_ADD, fn.instructions[1][0]
  end
end
