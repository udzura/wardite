# frozen_string_literal: true

require "test_helper"
require_relative "../spec/spectest_host"

class SpectestHostTest < Test::Unit::TestCase
  test "rejects mismatched spectest function imports during linking" do
    host = SpectestHost.new
    ["(param f32 i32)", "(param i32 f32) (result i32)"].each do |signature|
      buffer = make_buffer_from_wat(%((module (import "spectest" "print_i32_f32" (func #{signature})))))
      assert_raise_message("incompatible import type") do
        Wardite.new(buffer: buffer, import_object: {spectest: host}, enable_wasi: false)
      end
    end
  end
end
