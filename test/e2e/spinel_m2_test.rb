# frozen_string_literal: true

require 'test_helper'
require 'open3'
require_relative '../support/efflorescence_helper'
require_relative '../support/efflorescence_m2_cases'

class WarditeSpinelM2Test < Test::Unit::TestCase
  include EfflorescenceHelper
  ROOT = File.expand_path('../..', __dir__)
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

  test 'M2 globals snapshots and recursive calls in every native configuration' do
    with_wasm(EfflorescenceM2Cases::GLOBAL_WAT) do |file|
      MODES.each do |mode|
        [['get', [], 7], ['snapshot', [], -1], ['recursive', [3], 24], ['fixed', [], -1]].each do |export, args, expected|
          out, err, status = Open3.capture3(@binary, '--new-engine', *mode, '--invoke', export, '--', file, *args.map(&:to_s))
          assert status.success?, err
          assert_equal '', out
          assert_include err, "return value: I32(#{expected})\n"
        end
      end
    end
  end

  test 'M2 byte widths endpoint traps and unchanged memory on native API' do
    with_wasm(EfflorescenceM2Cases::MEMORY_WAT) do |file|
      Dir.mktmpdir do |dir|
        worker = File.join(dir, 'm2-memory')
        output, status = Open3.capture2e(ENV.fetch('SPINEL', 'spinel'), '--strict-require', '-O2',
          "-I#{ROOT}/lib", File.join(ROOT, 'test/spinel/efflorescence_m2_memory.rb'), '-o', worker)
        assert status.success?, output
        output, status = Open3.capture2e(worker, file)
        assert status.success?, output
        assert_equal "M2 memory passed\n", output
      end
    end
  end

  test 'M2 grow zeroing limits and subsequent calls on native API' do
    with_wasm(EfflorescenceM2Cases::GROW_WAT) do |file|
      Dir.mktmpdir do |dir|
        worker = File.join(dir, 'm2-grow')
        output, status = Open3.capture2e(ENV.fetch('SPINEL', 'spinel'), '--strict-require', '-O2',
          "-I#{ROOT}/lib", File.join(ROOT, 'test/spinel/efflorescence_m2_grow.rb'), '-o', worker)
        assert status.success?, output
        output, status = Open3.capture2e(worker, file)
        assert status.success?, output
        assert_equal "M2 grow passed\n", output
      end
      MODES.each do |mode|
        out, err, status = Open3.capture3(@binary, '--new-engine', *mode, '--invoke', 'callee', file)
        assert status.success?, err
        assert_equal '', out
        assert_include err, "return value: I32(53)\n"
      end
    end
    with_wasm('(module (memory 0) (func (export "grow") (param i32) (result i32) local.get 0 memory.grow))') do |file|
      [1, 65537, 0xffffffff].zip([0, -1, -1]).each do |delta, expected|
        _, err, status = Open3.capture3(@binary, '--new-engine', '--invoke', 'grow', '--', file, delta.to_s)
        assert status.success?, err
        assert_include err, "return value: I32(#{expected})\n"
      end
    end
  end

  test 'M2 foundation shared initialization and checked byte ranges on native API' do
    wat = '(module (memory 1) (data (i32.const 11) "\ff\c3\a9") (global i32 (i32.const 11)))'
    with_wasm(wat) do |file|
      Dir.mktmpdir do |dir|
        worker = File.join(dir, 'm2-api')
        output, status = Open3.capture2e(ENV.fetch('SPINEL', 'spinel'), '--strict-require', '-O2',
          "-I#{ROOT}/lib", File.join(ROOT, 'test/spinel/efflorescence_m2.rb'), '-o', worker)
        assert status.success?, output
        output, status = Open3.capture2e(worker, file)
        assert status.success?, output
        assert_equal "M2 foundation passed\n", output
      end
    end
  end
end
