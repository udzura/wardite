# frozen_string_literal: true

require 'test_helper'
require_relative 'support/efflorescence_helper'

class Wg3CoreRegressionsTest < Test::Unit::TestCase
  include EfflorescenceHelper

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
end
