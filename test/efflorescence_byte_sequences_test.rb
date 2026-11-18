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
