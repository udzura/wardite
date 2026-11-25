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
end
