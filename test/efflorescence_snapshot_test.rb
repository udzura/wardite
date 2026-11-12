# frozen_string_literal: true

require "test_helper"
require "rbconfig"
require "tmpdir"
require_relative "support/snapshot_fixture"

class EfflorescenceSnapshotTest < Test::Unit::TestCase
  include SnapshotFixture

  WARDITE = [RbConfig.ruby, "-I#{File.expand_path("../lib", __dir__)}", File.expand_path("../exe/wardite", __dir__)].freeze

  def setup
    @directory = Dir.mktmpdir("wardite-snapshot-test")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  data("direct host call" => :direct, "call_indirect to a host" => :indirect)
  test "a restored run repeats the checkpointed call and continues like the saved run" do |variant|
    wasm = write_snapshot_fixture(@directory, variant)
    saved_out, saved_err, saved = run_snapshot(WARDITE, @directory, wasm)
    assert_equal 3, saved.exitstatus, saved_err
    assert_include saved_err, "snapshot saved:"
    assert_match(/\A[a-z]{2}Z-1\n[a-z]{2}Z-2\n\z/, saved_out)
    assert_equal "#{(5050 % 26 + 97).chr}", saved_out[0]

    out, err, status = run_snapshot(WARDITE, @directory, wasm)
    assert_include err, "snapshot restored:"
    assert_equal [saved_out, 3], [out, status.exitstatus]
  end

  test "guest arguments select separate snapshots" do
    wasm = write_snapshot_fixture(@directory, :direct)
    run_snapshot(WARDITE, @directory, wasm, "a")
    _out, err, = run_snapshot(WARDITE, @directory, wasm, "b")
    assert_include err, "snapshot saved:"
    assert_equal 2, Dir.children(File.join(@directory, "snapshot")).size
  end

  test "a corrupt snapshot falls back to a normal start and is replaced" do
    wasm = write_snapshot_fixture(@directory, :direct)
    run_snapshot(WARDITE, @directory, wasm)
    path = Dir.glob(File.join(@directory, "snapshot", "*.snap")).fetch(0)
    bytes = File.binread(path)
    bytes.setbyte(bytes.bytesize - 1, bytes.getbyte(bytes.bytesize - 1) ^ 1)
    File.binwrite(path, bytes)

    out, err, status = run_snapshot(WARDITE, @directory, wasm)
    assert_include err, "snapshot miss:"
    assert_include err, "snapshot saved:"
    assert_match(/\A[a-z]{2}Z-1\n[a-z]{2}Z-2\n\z/, out)
    assert_equal 3, status.exitstatus
    _out, err, = run_snapshot(WARDITE, @directory, wasm)
    assert_include err, "snapshot restored:"
  end

  test "snapshot requires the MIR2 cache" do
    wasm = write_snapshot_fixture(@directory, :direct)
    _out, err, status = Open3.capture3(*WARDITE, "--new-engine", "--snapshot", @directory, "--", wasm)
    assert_false status.success?
    assert_include err, "--snapshot requires --new-engine and --mir-cache"
  end
end
