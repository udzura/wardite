# frozen_string_literal: true

require 'test_helper'
require_relative 'support/efflorescence_helper'

class Wg3CoreRegressionsTest < Test::Unit::TestCase
  include EfflorescenceHelper

  def import_memory(provider, minimum)
    load_efflorescence(<<~WAT, import_object: {env: provider.as_import_module})
      (module
        (memory (export "m") (import "env" "m") #{minimum})
        (func (export "grow") (result i32) i32.const 1 memory.grow)
        (func (export "size") (result i32) memory.size))
    WAT
  end

  def memory_provider
    load_efflorescence('(module (memory (export "m") 2 4))')
  end

  def initialized_segments
    provider = load_efflorescence('(module (global (export "base") i32 (i32.const 4)))')
    load_efflorescence(<<~WAT, import_object: {provider: provider.as_import_module})
      (module
        (global $base (import "provider" "base") i32)
        (global $next i32 (i32.add (global.get $base) (i32.const 4)))
        (func $target)
        (global $fn funcref (ref.func $target))
        (table 10 funcref (ref.null func))
        (elem (global.get $base) funcref (ref.func $target))
        (elem (global.get $next) funcref (global.get $fn))
        (memory 1)
        (data (global.get $base) "DDDD")
        (data (global.get $next) "\\88\\88\\88\\88")
        (func (export "elem") (param i32) (result funcref) local.get 0 table.get)
        (func (export "data") (param i32) (result i32) local.get 0 i32.load))
    WAT
  end

  test 'global.wast 374 reads a preceding named immutable global' do
    instance = load_efflorescence('(module (global $g i32 (i32.const 42)) (global (export "copy") i32 (global.get $g)))')
    assert_equal 42, instance.exports['copy'].value.value
  end

  test 'global.wast 398 rejects mutability 255 in a global import' do
    bytes = compile_efflorescence_wat('(module (import "x" "g" (global i32)))')
    assert_not_nil bytes.sub!("\x03\x7f\x00".b, "\x03\x7f\xff".b)
    assert_raise_message("unsupported global mutability flags") do
      Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false)
    end
  end

  test 'global.wast 415 rejects mutability 4 in a global definition' do
    bytes = compile_efflorescence_wat('(module (global i32 (i32.const 0)))')
    assert_not_nil bytes.sub!("\x7f\x00\x41".b, "\x7f\x04\x41".b)
    assert_raise_message("unsupported global mutability flags") do
      Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false)
    end
  end

  test 'global.wast 427 rejects mutability 255 in a global definition' do
    bytes = compile_efflorescence_wat('(module (global i32 (i32.const 0)))')
    assert_not_nil bytes.sub!("\x7f\x00\x41".b, "\x7f\xff\x41".b)
    assert_raise_message("unsupported global mutability flags") do
      Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false)
    end
  end

  test 'align.wast 987 rejects reserved flags above the low byte' do
    assert_raise_message("malformed memop flags") do
      Wardite::BinaryLoader.code_body(StringIO.new([0x28, 0x80, 0x02, 0, 0x0b].pack('C*')))
    end
  end

  test 'align.wast 1017 checks alignment before an oversized memory32 offset' do
    # Encode a u64::MAX offset directly so WAT parser limits cannot narrow it.
    body = [0, 0x41, 0, 0x28, 63, *([0xff] * 9), 1, 0x1a, 0x0b]
    bytes = "\0asm\1\0\0\0".b + [1, 4, 1, 0x60, 0, 0, 3, 2, 1, 0,
      5, 3, 1, 0, 1, 10, body.size + 2, 1, body.size, *body].pack('C*')
    error = assert_raise(Wardite::Efflorescence::TranslationError) do
      Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false)
    end
    assert_include error.message, 'invalid memory alignment'
  end

  test 'memory_grow.wast 329 re-exports the imported memory object' do
    provider = memory_provider
    assert_same provider.exports['m'], import_memory(provider, 2).as_import_module.memories[:m]
  end

  test 'memory_grow.wast 330 grows the shared memory in the consumer' do
    provider = memory_provider
    assert_equal 2, import_memory(provider, 2).runtime.call_unboxed('grow', [])
    assert_equal 3, provider.exports['m'].current
  end

  test 'memory_grow.wast 331 links against the current page count' do
    first = import_memory(memory_provider, 2)
    assert_raise(Wardite::LinkError) { import_memory(first, 3) }
    first.runtime.call_unboxed('grow', [])
    assert_same first.exports['m'], import_memory(first, 3).exports['m']
  end

  test 'memory_grow.wast 336 reads the size through a second import' do
    first = import_memory(memory_provider, 2)
    second = import_memory(first, 2)
    first.runtime.call_unboxed('grow', [])
    assert_equal 3, second.runtime.call_unboxed('size', [])
  end

  test 'global.wast 659 starts untouched table slots with a null reference' do
    assert_nil initialized_segments.runtime.call_unboxed('elem', [0])
  end

  test 'global.wast 660 places a function at an imported global offset' do
    instance = initialized_segments
    reference = instance.runtime.call_unboxed('elem', [4])
    assert_same instance, reference.instance
    assert_equal 0, reference.index
  end
end
