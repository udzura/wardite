# frozen_string_literal: true

require 'test_helper'
require_relative 'support/efflorescence_helper'
require_relative 'support/efflorescence_m1_cases'

class EfflorescenceM1Test < Test::Unit::TestCase
  include EfflorescenceHelper
  include EfflorescenceM1Cases
  E = Wardite::Efflorescence
  OP = E::Opcode
  MODES = [{}, {disabled_optimizations: [:all]}, {disabled_optimizations: [:flat]},
           {disabled_optimizations: [:frames]}, {mir_profile: true}].freeze

  def load_bytes(bytes, **options)
    Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false,
      engine: :efflorescence, **options).runtime
  end

  def validated_bytes(wat)
    bytes = compile_efflorescence_wat(wat)
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'input.wasm')
      File.binwrite(file, bytes)
      output, status = Open3.capture2e('wasm-tools', 'validate', file)
      assert status.success?, output
    end
    bytes
  end

  test 'all i32 comparisons use signed or unsigned values at the boundaries' do
    ops = %w[eq ne lt_s lt_u gt_s gt_u le_s le_u ge_s ge_u]
    wat = '(module ' + ops.map { |op| "(func (export \"#{op}\") (param i32 i32) (result i32) local.get 0 local.get 1 i32.#{op})" }.join + ')'
    bytes = validated_bytes(wat)
    modes = MODES + %i[copy immediate branch superinstruction inline].map { |pass| {disabled_optimizations: [pass]} }
    modes.each do |mode|
      vm = load_bytes(bytes, **mode)
      [0, 1, 0xffffffff, 0x80000000, 0x7fffffff].repeated_permutation(2) do |a, b|
        ops.each do |op|
          left, right = a, b
          if op.end_with?('_s')
            left = a >= 2**31 ? a - 2**32 : a
            right = b >= 2**31 ? b - 2**32 : b
          end
          comparison = {'eq' => :==, 'ne' => :!=, 'lt' => :<, 'gt' => :>, 'le' => :<=, 'ge' => :>=}.fetch(op.split('_').first)
          expected = left.public_send(comparison, right) ? 1 : 0
          assert_equal expected, vm.call_unboxed(op, [a, b]), "#{op}(#{a}, #{b}) #{mode}"
        end
      end
    end
  end

  test 'div rem shifts rotates counts and sign extensions preserve Wasm boundaries and traps' do
    cases = {
      'div_s' => [[-7, 3, -2], [7, -3, -2], [-7, -3, 2], [0x80000000, 1, 0x80000000]],
      'div_u' => [[0xffffffff, 2, 0x7fffffff]],
      'rem_s' => [[-7, 3, -1], [7, -3, 1], [-7, -3, -1], [0x80000000, -1, 0]],
      'rem_u' => [[0xffffffff, 2, 1]],
      'and' => [[0xaaaaaaaa, 0x55555555, 0]], 'or' => [[0xaaaaaaaa, 0x55555555, -1]],
      'shr_s' => [0, 31, 32, 33].map { |n| [0x80000000, n, (-2**31 >> (n % 32))] },
      'rotl' => [[0x80000001, 0, 0x80000001], [0x80000001, 31, 0xc0000000], [0x80000001, 32, 0x80000001], [0x80000001, 33, 3]],
      'rotr' => [[0x80000001, 0, 0x80000001], [0x80000001, 31, 3], [0x80000001, 32, 0x80000001], [0x80000001, 33, 0xc0000000]],
      'clz' => [[0, 32], [1, 31], [0x80000000, 0]],
      'ctz' => [[0, 32], [1, 0], [0x80000000, 31]],
      'popcnt' => [[0, 0], [0xffffffff, 32], [0x80000001, 2]],
      'extend8_s' => [[127, 127], [128, 0xffffff80], [255, -1], [256, 0]],
      'extend16_s' => [[32767, 32767], [32768, 0xffff8000], [65535, -1], [65536, 0]]
    }
    wat = '(module ' + cases.map do |op, vectors|
      arity = vectors.first.size - 1
      "(func (export \"#{op}\") (param #{(['i32'] * arity).join(' ')}) (result i32) #{arity.times.map { |i| "local.get #{i}" }.join(' ')} i32.#{op})"
    end.join + ')'
    bytes = validated_bytes(wat)
    (MODES + %i[copy immediate branch superinstruction inline].map { |pass| {disabled_optimizations: [pass]} }).each do |mode|
      vm = load_bytes(bytes, **mode)
      cases.each do |op, vectors|
        vectors.each { |vector| assert_equal vector.last & 0xffffffff, vm.call_unboxed(op, vector[0...-1]), "#{op} #{vector}" }
      end
      %w[div_s div_u rem_s rem_u].each do |op|
        assert_raise(Wardite::EvalError) { vm.call_unboxed(op, [7, 0]) }
      end
      assert_raise(Wardite::IntegerOverflow) { vm.call_unboxed('div_s', [0x80000000, -1]) }
      assert_equal 2, vm.call_unboxed('div_s', [7, 3])
    end
    # Even a discarded result must retain its trap through all optimizer passes.
    vm = load_efflorescence('(module (func (export "run") i32.const 1 i32.const 0 i32.div_s drop))').runtime
    assert_raise(Wardite::EvalError) { vm.call_unboxed('run', []) }
  end

  test 'ordinary i32 operations agree with the stack engine and independent values' do
    wat = <<~WAT
      (module
        (func (export "run") (param i32) (result i32)
          local.get 0 if (result i32)
            i32.const -7 i32.const 3 i32.div_s
          else i32.const 7 i32.const -3 i32.rem_s end
          i32.const 42 i32.const 1 select)
        (func (export "table") (param i32) (result i32)
          block (result i32) i32.const 42 local.get 0 br_table 0 0 end))
    WAT
    bytes = validated_bytes(wat)
    old = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false).runtime
    MODES.each do |mode|
      vm = load_bytes(bytes, **mode)
      %w[run table].each do |name|
        [0, 1, -1].each do |arg|
          expected = name == 'run' ? (arg == 0 ? 1 : 0xfffffffe) : 42
          assert_equal expected, old.call(name, [arg]).value
          assert_equal expected, vm.call_unboxed(name, [arg])
        end
      end
    end
  end

  test 'if reachability snapshots select eager operands and table transfers' do
    wat = <<~WAT
      (module
        (func (export "snapshot") (param i32) (result i32)
          local.get 0 local.get 0 if i32.const 99 local.set 0 else i32.const 17 local.set 0 end
          local.get 0 i32.sub)
        (func (export "one_return") (param i32) (result i32)
          local.get 0 if (result i32) i32.const 42 return else i32.const 42 end)
        (func (export "both_return") (param i32) (result i32)
          local.get 0 if i32.const 42 return else i32.const 42 return end unreachable)
        (func (export "nested") (param i32) (result i32)
          local.get 0 if (result i32) i32.const 0 if (result i32) unreachable else i32.const 42 end
          else i32.const 42 end)
        (func (export "select") (param i32) (result i32) i32.const 42 i32.const 13 local.get 0 select)
        (func (export "eager") (result i32) i32.const 42 i32.const 1 i32.const 0 i32.div_s i32.const 1 select)
        (func (export "table") (param i32) (result i32)
          block $out (result i32)
            block $middle (result i32)
              block $inner (result i32)
                i32.const 42 local.get 0 br_table $inner $middle $inner $out
              end i32.const 1 i32.add
            end i32.const 2 i32.add
          end)
        (func (export "conditional_result") (param i32) (result i32)
          block (result i32) i32.const 42 local.get 0 br_if 0 drop i32.const 13 end))
    WAT
    bytes = validated_bytes(wat)
    MODES.each do |mode|
      vm = load_bytes(bytes, **mode)
      [0, 1].each do |condition|
        assert_equal ((condition == 0 ? -17 : -98) & 0xffffffff), vm.call_unboxed('snapshot', [condition])
        %w[one_return both_return nested].each { |name| assert_equal 42, vm.call_unboxed(name, [condition]) }
        assert_equal condition == 0 ? 13 : 42, vm.call_unboxed('select', [condition])
        assert_equal condition == 0 ? 13 : 42, vm.call_unboxed('conditional_result', [condition])
      end
      [[0,45], [1,44], [2,45], [3,42], [-1,42]].each { |index, value| assert_equal value, vm.call_unboxed('table', [index]) }
      assert_raise(Wardite::EvalError) { vm.call_unboxed('eager', []) }
    end
  end

  EH_CASES.each do |name, wat, calls|
    test "EH #{name} in every execution mode" do
      bytes = validated_bytes(wat)
      MODES.each do |mode|
        vm = load_bytes(bytes, **mode)
        2.times do
          calls.each { |export, args, expected| assert_equal expected, vm.call_unboxed(export, args), "#{name} #{mode}" }
        end
        vm.semantic_ir.functions.each_with_index do |function, i|
          if function.uses_eh
            assert_equal function.instructions.map(&:operands), vm.optimized_ir.function_at(i).instructions.map(&:operands)
          end
        end
      end
    end
  end

  test 'uncaught values own immutable payloads and instance-specific tags; trap and exception recovery' do
    wat = <<~WAT
      (module (tag $e (param i32))
        (func $leaf i32.const 42 throw $e)
        (func (export "raise") call $leaf)
        (func (export "null") (local exnref)
          block $caught try_table (catch_all $caught) local.get 0 throw_ref end end)
        (func (export "trap")
          block $caught try_table (catch_all $caught) unreachable end end)
        (func (export "zero")
          block $caught try_table (catch_all $caught) i32.const 1 i32.const 0 i32.div_s drop end end)
        (func (export "ok") (result i32) i32.const 42))
    WAT
    bytes = validated_bytes(wat)
    MODES.each do |mode|
      vm = load_bytes(bytes, **mode)
      other = load_bytes(bytes, **mode)
      error = assert_raise(Wardite::UncaughtWasmException) { vm.call_unboxed('raise', []) }
      assert_equal [42], error.payload
      assert_predicate error.payload, :frozen?
      assert_same vm.instance.tags[0], error.tag
      assert_not_same other.instance.tags[0], error.tag
      assert_equal 42, vm.call_unboxed('ok', [])
      assert_raise(Wardite::EvalError) { vm.call_unboxed('null', []) }
      assert_raise(Wardite::Unreachable) { vm.call_unboxed('trap', []) }
      assert_raise(Wardite::EvalError) { vm.call_unboxed('zero', []) }
      assert_equal 42, vm.call_unboxed('ok', [])
    end
    assert_raise(Wardite::UncaughtWasmException) do
      load_efflorescence('(module (tag $e) (func $start throw $e) (start $start))')
    end
  end

  test 'frame release and reuse clear references and handler state' do
    fn = E::Function.new(0, [], [], 1, local_types: [:exnref])
    pool = E::FramePool.new(fn, true)
    frame = pool.acquire(-1)
    frame.exception_registers[0] = E::ExceptionValue.new(E::Tag.new([:i32]), [42])
    frame.handlers << 0
    pool.release(frame)
    assert_equal [nil], frame.exception_registers
    assert_empty frame.handlers
    reused = pool.acquire(-1)
    assert_same frame, reused
    assert_equal [nil], reused.exception_registers
  end

  test 'exceptional definitions exclude the unfinished call and later instructions' do
    fn = E::Function.new(0, [], [:i32], 0)
    result = fn.allocate_register(0)
    fn.handlers << E::HandlerDescriptor.new([E::CatchTarget.new(-1, [], -1, 4, 0)])
    fn.replace_instructions([[OP::EH_ENTER, 0], [OP::CALL, result, 0], [OP::EH_TRIM, 0], [OP::RETURN, result], [OP::RETURN, result]].map { |a| E::Instruction.new(a) })
    error = assert_raise(E::TranslationError) { E::RegisterValidation.new.validate(fn) }
    assert_include error.message, 'read before definition'
    # Neither a later definition nor another clause's writes define this edge.
    fn.instructions[1] = E::Instruction.new([OP::CALL, -1, 0])
    fn.instructions[2] = E::Instruction.new([OP::COPY, result, fn.allocate_constant(42)])
    fn.instructions[3] = E::Instruction.new([OP::RETURN, result])
    assert_raise(E::TranslationError) { E::RegisterValidation.new.validate(fn) }
    fn.handlers[0].clauses << E::CatchTarget.new(0, [result], -1, 4, 0)
    assert_raise(E::TranslationError) { E::RegisterValidation.new.validate(fn) }
  end

  test 'handler shapes must agree at normal joins' do
    fn = E::Function.new(0, [:i32], [], 0)
    fn.handlers << E::HandlerDescriptor.new([])
    fn.replace_instructions([[OP::BR_IF, 0, 2], [OP::EH_ENTER, 0], [OP::RETURN, -1]].map { |a| E::Instruction.new(a) })
    assert_raise(E::TranslationError) { E::RegisterValidation.new.validate(fn) }
  end

  test 'parallel multi-value transfers preserve aliases and reference types' do
    fn = E::Function.new(0, [:i32, :i32], [], 0)
    translator = E::Translator.new(load_efflorescence('(module)').runtime.instance)
    translator.instance_variable_set(:@function, fn)
    translator.send(:parallel_copy, [0, 1], [1, 0])
    fn.replace_instructions(fn.instructions + [E::Instruction.new([OP::RETURN, -1])])
    E::RegisterValidation.new.validate(fn)
    registers = [11, 31, 0, 0]
    fn.instructions[0...-1].each { |i| registers[i[1]] = registers[i[2]] }
    assert_equal [31, 11], registers.first(2)
    refs = E::Function.new(0, [], [], 2, local_types: [:exnref, :exnref])
    translator.instance_variable_set(:@function, refs)
    translator.send(:parallel_copy, [0, 1], [1, 0])
    refs.instructions << E::Instruction.new([OP::RETURN, -1])
    E::RegisterValidation.new.validate(refs)
    first = E::ExceptionValue.new(E::Tag.new([]), [])
    second = E::ExceptionValue.new(E::Tag.new([]), [])
    bank = [first, second, nil, nil]
    refs.instructions[0...-1].each { |i| bank[i[1]] = bank[i[2]] }
    assert_same second, bank[0]
    assert_same first, bank[1]
  end

  test 'register replacement covers throw reads and all catch destinations' do
    fn = E::Function.new(0, [:i32, :i32], [], 2, local_types: [:exnref, :exnref])
    fn.throw_sites << E::ThrowSite.new(0, [0, 1])
    fn.handlers << E::HandlerDescriptor.new([E::CatchTarget.new(0, [0, 1], 2, 0, 0)])
    fn.instructions << E::Instruction.new([OP::THROW, 0])
    copy = fn.copy
    copy.replace_register_references!([1, 0, 3, 2])
    assert_equal [1, 0], copy.reads(copy.instructions[0])
    assert_equal [1, 0, 3], copy.handlers[0].clauses[0].destinations
    assert_equal [0, 1], fn.throw_sites[0].payload_registers
    assert_equal [0, 1, 2], fn.handlers[0].clauses[0].destinations
  end

  test 'profiling and lowering remap catch PCs without mutating semantic tables' do
    vm = load_efflorescence(ACCEPTANCE, mir_profile: true).runtime
    original = vm.semantic_ir.function_at(2)
    instrumented = vm.ir.function_at(2)
    before = original.handlers.map { |h| h.clauses.map(&:target_pc) }
    assert_not_same original.handlers[0], instrumented.handlers[0]
    instrumented.handlers.each_with_index do |handler, i|
      handler.clauses.each_with_index do |clause, j|
        assert_equal before[i][j] * 2, clause.target_pc
        assert_equal clause.target_pc * 4, instrumented.flat_handlers[i].clauses[j].target_pc
      end
    end
    assert_equal 42, vm.call_unboxed('rethrow', [])
    assert_equal before, original.handlers.map { |h| h.clauses.map(&:target_pc) }
    assert_include vm.dump_mir, 'handler 0:'
    assert_include vm.dump_mir, 'throw 0:'
  end
end
