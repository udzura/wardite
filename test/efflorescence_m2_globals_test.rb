# frozen_string_literal: true

require 'test_helper'
require 'rbconfig'
require_relative 'support/efflorescence_helper'
require_relative 'support/efflorescence_m2_cases'

class EfflorescenceM2GlobalsTest < Test::Unit::TestCase
  include EfflorescenceHelper
  include EfflorescenceM2Cases
  E = Wardite::Efflorescence

  test 'global values synchronize across host calls traps and shared stores' do
    root = File.expand_path('..', __dir__)
    Dir.mktmpdir('wardite-global-sync') do |dir|
      source = File.join(__dir__, 'support/efflorescence_global_sync.wat')
      probe = File.join(__dir__, 'spinel/efflorescence_global_sync.rb')
      wasm = File.join(dir, 'globals.wasm')
      File.binwrite(wasm, compile_efflorescence_wat(File.read(source)))
      output, status = Open3.capture2e(RbConfig.ruby, "-I#{root}/lib", probe, wasm)
      assert status.success?, output
      assert_equal "global synchronization passed\n", output
    end
  end

  test 'global snapshots calls recursion persistence and instance separation agree with the stack VM' do
    bytes = compile_efflorescence_wat(GLOBAL_WAT)
    MODES.each do |mode|
      fresh = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false, engine: :efflorescence, **mode)
      old = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false)
      independent = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false, engine: :efflorescence, **mode)
      vm = fresh.runtime
      [['get', [], 7], ['direct', [40], 7], ['snapshot', [], 0xffffffff], ['get', [], 41],
       ['recursive', [3], 126], ['get', [], 44], ['fixed', [], 0xffffffff],
       ['set', [0xffffffff], nil], ['snapshot', [], 0xffffffff], ['get', [], 0]].each do |name, args, expected|
        assert_equal expected, vm.call_unboxed(name, args), "#{mode} #{name}"
        boxed = old.runtime.call(name, args)
        assert_equal expected, boxed&.value
        assert_equal old.store.globals.map { |g| g.value.value }, fresh.store.globals.map { |g| g.value.value }
      end
      assert_equal 7, independent.runtime.call_unboxed('get', [])
      assert_not_same independent.store.globals[0], fresh.store.globals[0]
      assert_instance_of Wardite::I32, fresh.store.globals[0].value
      # Store functions stay out of every local pass and both directions of inlining.
      vm.semantic_ir.functions.each_with_index do |fn, i|
        next unless fn.uses_store
        assert_equal fn.instructions.map(&:operands), vm.optimized_ir.function_at(i).instructions.map(&:operands)
      end
    end
  end

  test 'global access rejects wrong operand types dead bad indices and immutable writes' do
    ['(module (global (mut i32) (i32.const 0)) (func (local exnref) local.get 0 global.set 0))',
     '(module (global (mut i32) (i32.const 0)) (func unreachable global.set 1))',
     '(module (global i32 (i32.const 0)) (func unreachable global.set 0))'].each do |wat|
      assert_raise(E::TranslationError) { load_efflorescence(wat) }
    end
    assert_raise(E::TranslationError) do
      load_efflorescence('(module (global (mut f64) (f64.const 0)) (func unreachable i32.const 0 global.set 0))')
    end
    assert_raise(Wardite::LoadError) do
      load_efflorescence('(module (global i32 (i64.const 0)) (func global.get 0 drop))')
    end
  end
end
