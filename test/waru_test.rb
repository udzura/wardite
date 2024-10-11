# frozen_string_literal: true

require "test_helper"

class WaruTest < Test::Unit::TestCase
  test "VERSION" do
    assert do
      ::Waru.const_defined?(:VERSION)
    end
  end

  test "something useful" do
    assert_equal("expected", "actual")
  end
end
