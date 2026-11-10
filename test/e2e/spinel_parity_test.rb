# frozen_string_literal: true

require "test_helper"
require_relative "../support/efflorescence_parity"

class WarditeSpinelParityTest < Test::Unit::TestCase
  test "native parity runner compares state and the position of a trap" do
    omit "Run make spinel-test to test the native executable" unless ENV["WARDITE_SPINEL_BIN"]
    assert_nothing_raised do
      EfflorescenceParity.run([EfflorescenceParity.state_fixture], runtime: :spinel)
    end
  end
end
