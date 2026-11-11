# frozen_string_literal: true

require 'test_helper'
require 'open3'
require_relative '../support/efflorescence_helper'
require_relative '../support/efflorescence_m1_cases'

class WarditeSpinelM1Test < Test::Unit::TestCase
  include EfflorescenceHelper
  include EfflorescenceM1Cases
  MODES = [[], ['--mir-disable', 'all'], ['--mir-disable', 'frames'], ['--mir-profile']].freeze

  def setup
    @binary = ENV['WARDITE_SPINEL_BIN']
    omit 'Run make spinel-test to test the native executable' unless @binary
    assert File.executable?(@binary)
  end

  def with_wasm(wat)
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'input.wasm')
      File.binwrite(file, compile_efflorescence_wat(wat))
      yield file
    end
  end

  def assert_native(file, export, args, expected, options)
    output, error, status = Open3.capture3(@binary, '--new-engine', *options,
      '--invoke', export, '--', file, *args.map(&:to_s))
    assert status.success?, "#{options} #{export}: #{error}"
    assert_equal '', output
    signed = expected >= 0x80000000 ? expected - 0x100000000 : expected
    assert_include error, "return value: I32(#{signed})\n"
    assert_include error, 'dispatches=' if options.include?('--mir-profile')
  end

  EH_CASES.each do |name, wat, calls|
    test "M1 EH #{name}" do
      with_wasm(wat) do |file|
        MODES.each do |mode|
          calls.each { |export, args, expected| assert_native(file, export, args, expected, mode) }
        end
      end
    end
  end

  test 'M1 integer operations and control paths across native execution modes' do
    # Fixed independent boundary expectations also catch native-word overflow.
    vectors = {
      'div_s' => [[-7, 3], 0xfffffffe], 'div_u' => [[-1, 2], 0x7fffffff],
      'rem_s' => [[0x80000000, -1], 0], 'rem_u' => [[-1, 2], 1],
      'shr_s' => [[0x80000000, 33], 0xc0000000],
      'rotl' => [[0x80000001, 31], 0xc0000000], 'rotr' => [[0x80000001, 33], 0xc0000000],
      'clz' => [[0], 32], 'ctz' => [[0], 32], 'popcnt' => [[-1], 32],
      'extend8_s' => [[128], 0xffffff80], 'extend16_s' => [[32768], 0xffff8000],
      'lt_s' => [[-1, 0], 1], 'lt_u' => [[-1, 0], 0], 'eq' => [[-1, -1], 1],
      'and' => [[-1, 42], 42], 'or' => [[32, 10], 42]
    }
    wat = '(module ' + vectors.map do |op, (args, _)|
      "(func (export \"#{op}\") (param #{(['i32'] * args.size).join(' ')}) (result i32) #{args.each_index.map { |i| "local.get #{i}" }.join(' ')} i32.#{op})"
    end.join + <<~WAT
      (func (export "control") (param i32) (result i32)
        block (result i32)
          i32.const 42 local.get 0 br_table 0 0
        end
        local.get 0 if (result i32) i32.const 0 else i32.const 0 end
        i32.const 1 select))
    WAT
    with_wasm(wat) do |file|
      modes = MODES + %w[copy immediate branch superinstruction inline].map { |pass| ['--mir-disable', pass] }
      modes.each do |mode|
        vectors.each { |op, (args, expected)| assert_native(file, op, args, expected, mode) }
        [0, 1, -1].each { |arg| assert_native(file, 'control', [arg], 42, mode) }
      end
    end
  end

  test 'M1 native API preserves errors and recovers on the same VM after pooled reference reuse' do
    wat = <<~WAT
      (module (tag $e (param i32))
        (func $leaf (param i32) (local exnref)
          local.get 0 if
            block $caught (result i32 exnref)
              try_table (catch_ref $e $caught) i32.const 42 throw $e end unreachable
            end local.set 1 drop return
          end local.get 1 throw_ref)
        (func (export "raise") i32.const 42 throw $e)
        (func (export "null") (local exnref) local.get 0 throw_ref)
        (func (export "reuse") i32.const 1 call $leaf i32.const 0 call $leaf)
        (func (export "ok") (result i32) i32.const 42))
    WAT
    with_wasm(wat) do |file|
      Dir.mktmpdir do |dir|
        worker = File.join(dir, 'm1-api')
        root = File.expand_path('../..', __dir__)
        output, status = Open3.capture2e(ENV.fetch('SPINEL', 'spinel'), '--strict-require', '-O2',
          "-I#{root}/lib", File.join(root, 'test/spinel/efflorescence_m1.rb'), '-o', worker)
        assert status.success?, output
        output, status = Open3.capture2e(worker, file)
        assert status.success?, output
        assert_equal "M1 API recovery passed\n", output
      end
    end
  end

  test 'native register validation handles large joins and a backedge' do
    diamonds = Array.new(96, <<~WAT).join
      local.get 0 if (result i32) i32.const 42 else i32.const 42 end local.set 1
    WAT
    wat = <<~WAT
      (module
        (func (export "run") (param i32) (result i32) (local i32)
          loop
            #{diamonds}
            local.get 0 i32.const 1 i32.sub local.tee 0 br_if 0
          end
          local.get 1))
    WAT
    with_wasm(wat) do |file|
      assert_native(file, 'run', [2], 42, ['--mir-disable', 'all'])
    end
  end

  test 'M1 traps bypass catch_all and uncaught exceptions report their own error' do
    wat = <<~WAT
      (module (tag $e (param i32))
        (func (export "raise") i32.const 42 throw $e)
        (func (export "null") (local exnref)
          block $done try_table (catch_all $done) local.get 0 throw_ref end end)
        (func (export "zero")
          block $done try_table (catch_all $done) i32.const 1 i32.const 0 i32.div_u drop end end)
        (func (export "overflow")
          i32.const -2147483648 i32.const -1 i32.div_s drop))
    WAT
    with_wasm(wat) do |file|
      MODES.each do |mode|
        {'raise' => 'UncaughtWasmException', 'null' => 'throw_ref null', 'zero' => 'integer divide by zero', 'overflow' => 'IntegerOverflow'}.each do |export, message|
          _, error, status = Open3.capture3(@binary, '--new-engine', *mode, '--invoke', export, '--', file)
          assert_false status.success?
          assert_include error, message
        end
      end
    end
  end
end
