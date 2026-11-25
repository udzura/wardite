# frozen_string_literal: true

require 'test_helper'
require_relative 'support/efflorescence_helper'

class Wg3CoreRegressionsTest < Test::Unit::TestCase
  include EfflorescenceHelper

  test 'global.wast 374 reads a preceding named immutable global' do
    instance = load_efflorescence('(module (global $g i32 (i32.const 42)) (global (export "copy") i32 (global.get $g)))')
    assert_equal 42, instance.exports['copy'].value.value
  end
end
