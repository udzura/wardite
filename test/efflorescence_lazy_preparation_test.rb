# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"
require_relative "support/mir_generation_digest"

class EfflorescenceLazyPreparationTest < Test::Unit::TestCase
  include EfflorescenceHelper

  def load_vm(wasm, **options)
    Wardite::BinaryLoader.load_from_buffer(StringIO.new(wasm), enable_wasi: false, **options).runtime
  end

  test "start, exports, indirect calls and host reentry prepare only reached functions" do
    wasm = compile_efflorescence_wat(<<~WAT)
      (module
        (type $t (func (result i32)))
        (import "env" "host" (func $host (type $t)))
        (table 1 funcref) (elem (i32.const 0) func $value)
        (func $start) (start $start)
        (func (export "run") (result i32) call $host)
        (func (export "callback") (result i32) i32.const 0 call_indirect (type $t))
        (func $value (result i32) call $leaf)
        (func $leaf (result i32) i32.const 42)
        (func (export "unused") (result i32) i32.const 99))
    WAT
    vm = nil
    vm = load_vm(wasm, disabled_optimizations: [:all], import_object: {env: {host: ->(*) { vm.call_unboxed(:callback, []) }}})
    functions = vm.instance_variable_get(:@ir).functions
    assert_equal [false, true, true, true, true, true], functions.map { |fn| fn.bytecode.empty? }
    assert_equal 42, vm.call_unboxed(:run, [])
    assert_equal [false, false, false, false, false, true], functions.map { |fn| fn.bytecode.empty? }
    assert_same functions[4], functions[3].calls.first.callee
    code = functions.map(&:bytecode)
    assert_equal 42, vm.call_unboxed(:run, [])
    functions.zip(code) { |fn, original| assert_same original, fn.bytecode }
  end

  test "resume prepares a pending frame before using its saved program counter" do
    require "wardite/efflorescence/snapshot"
    wasm = compile_efflorescence_wat(<<~WAT)
      (module
        (global $g (mut i32) (i32.const 0))
        (func (param i32) local.get 0 global.set $g)
        (func (export "value") (result i32) global.get $g))
    WAT
    eager = load_vm(wasm, mir_cache_eager: true).ir.functions.first
    registers = eager.initial_registers.dup
    registers[0] = 73
    saved = Wardite::Efflorescence::SavedFrame.new(eager.pool_index, 0, -1, registers, [])
    vm = load_vm(wasm)
    functions = vm.instance_variable_get(:@ir).functions
    vm.resume([saved])
    assert_equal eager.bytecode, functions.first.bytecode
    assert_empty functions.last.bytecode
    assert_equal 73, vm.call_unboxed(:value, [])
  end

  test "inlining and profiling produce eager MIR in either first-call order" do
    wasm = compile_efflorescence_wat(File.read(MIX_WAT))
    [false, true].each do |profile|
      eager = load_vm(wasm, mir_cache_eager: true, mir_profile: profile)
      expected = MIRGenerationDigest.ir(eager.ir)
      [false, true].each do |reverse|
        lazy = load_vm(wasm, mir_profile: profile)
        functions = lazy.instance_variable_get(:@ir).functions
        preparer = lazy.instance_variable_get(:@preparer)
        (reverse ? functions.reverse : functions).each { |fn| preparer.prepare(fn) }
        assert_equal expected, MIRGenerationDigest.ir(lazy.ir)
      end
    end
  end

  test "a failed finish preserves the original function and permits retry" do
    wasm = compile_efflorescence_wat('(module (func (export "answer") (result i32) i32.const 42))')
    vm = load_vm(wasm, disabled_optimizations: [:all])
    fn = vm.instance_variable_get(:@ir).functions.first
    instructions = fn.instructions.dup
    fn.instructions.clear
    assert_raise(Wardite::Efflorescence::TranslationError) { vm.call_unboxed(:answer, []) }
    assert_empty fn.bytecode
    assert_empty fn.calls
    fn.instructions.concat(instructions)
    assert_equal 42, vm.call_unboxed(:answer, [])
  end
end
