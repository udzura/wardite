# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../support/snapshot_fixture"

class WarditeSpinelSnapshotTest < Test::Unit::TestCase
  include SnapshotFixture

  def setup
    @binary = ENV["WARDITE_SPINEL_BIN"]
    omit "Run make spinel-test to test the native executable" unless @binary
  end

  data("direct host call" => :direct, "call_indirect to a host" => :indirect)
  test "Spinel saves and resumes a startup snapshot" do |variant|
    Dir.mktmpdir do |directory|
      wasm = write_snapshot_fixture(directory, variant)
      saved_out, saved_err, saved = run_snapshot([@binary], directory, wasm)
      assert_equal 3, saved.exitstatus, saved_err
      assert_include saved_err, "snapshot saved:"
      assert_match(/\A[a-z]{2}Z-1\n[a-z]{2}Z-2\n\z/, saved_out)

      out, err, status = run_snapshot([@binary], directory, wasm)
      assert_include err, "snapshot restored:"
      assert_equal [saved_out, 3], [out, status.exitstatus]
    end
  end
end
