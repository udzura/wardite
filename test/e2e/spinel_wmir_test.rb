# frozen_string_literal: true

require "test_helper"
require "open3"
require_relative "../support/efflorescence_helper"
require_relative "../support/snapshot_fixture"

class EfflorescenceWMIRTest < Test::Unit::TestCase
  include EfflorescenceHelper
  include SnapshotFixture

  def setup
    @dir = Dir.mktmpdir
    @wasm = File.join(@dir, "input.wasm")
    @artifact = File.join(@dir, "module.wmir")
    @cli = ENV["WARDITE_SPINEL_BIN"] ? [ENV.fetch("WARDITE_SPINEL_BIN")] :
      [RbConfig.ruby, "-I#{File.expand_path("../../lib", __dir__)}", File.expand_path("../../exe/wardite", __dir__)]
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def compile(*options)
    out, err, status = Open3.capture3(*@cli, "--compile-wmir", @artifact, *options, "--", @wasm)
    assert_predicate status, :success?, err
    assert_equal "", out
  end

  test "a relocated artifact restores functions and its pass set without the Wasm" do
    FileUtils.cp(File.expand_path("../add.wasm", __dir__), @wasm)
    compile("--mir-enable", "cse")
    File.unlink(@wasm)
    renamed = File.join(@dir, "moved.wmir")
    File.rename(@artifact, renamed)
    ["checksum", "sha256"].each do |mode|
      _, err, status = Open3.capture3(*@cli, "--mir-cache-verify", mode, "--invoke", "add", "--", renamed, "40", "2")
      assert_predicate status, :success?, err
      assert_include err, "I32(42)"
    end
    _, err, status = Open3.capture3(*@cli, "--mir-disable", "cse", "--invoke", "add", "--", renamed, "40", "2")
    assert_false status.success?
    assert_include err, "incompatible WMIR"
  end

  test "compilation does not call the start function and execution links imports afresh" do
    File.binwrite(@wasm, compile_efflorescence_wat(<<~WAT))
      (module (import "host" "initialize" (func $initialize))
        (func $start call $initialize) (start $start))
    WAT
    compile
    unless ENV["WARDITE_SPINEL_BIN"]
      calls = []
      Wardite.new(path: @artifact, import_object: {host: {initialize: ->(*) { calls << :called; nil }}})
      assert_equal [:called], calls
    end
    _, err, status = Open3.capture3(*@cli, "--invoke", "f", "--", @artifact)
    assert_false status.success?
    assert_include err, "module host not found"
  end

  test "lazy MIR and Wasm inspection retain the original mapping after atomic replacement" do
    File.binwrite(@wasm, compile_efflorescence_wat('(module (func (export "value") (result i32) (local i32) i32.const 42))'))
    # Exercise the embedding API with the current process's runtime.
    Wardite.new(path: @wasm, emit_wmir: @artifact)
    instance = Wardite.new(path: @artifact)
    File.binwrite(@wasm, compile_efflorescence_wat('(module (func (export "value") (result i32) i32.const 9))'))
    Wardite.new(path: @wasm, emit_wmir: @artifact)
    assert_true instance.runtime.ir.functions.fetch(0).cache_pending
    assert_equal [:i32_const, :end], instance.code_section.func_codes.fetch(0).body.map { |op| op[1] }
    assert_equal 42, instance.runtime.call("value", []).value
    assert_equal 9, Wardite.new(path: @artifact).runtime.call("value", []).value
  end

  test "rejects damaged metadata, unsupported versions, truncation and strong digest mismatches" do
    FileUtils.cp(File.expand_path("../add.wasm", __dir__), @wasm)
    compile
    good = File.binread(@artifact)
    [8, 68, 132, good.bytesize - 1].each do |offset|
      bad = good.dup
      bad.setbyte(offset, bad.getbyte(offset) ^ 0x01)
      File.binwrite(@artifact, bad)
      _, err, status = Open3.capture3(*@cli, "--mir-cache-verify", "sha256", "--invoke", "add", "--", @artifact, "1", "2")
      assert_false status.success?
      assert_include err, "WMIR"
    end
    File.binwrite(@artifact, good.byteslice(0, good.bytesize - 1))
    _, err, status = Open3.capture3(*@cli, "--invoke", "add", "--", @artifact, "1", "2")
    assert_false status.success?
    assert_include err, "invalid WMIR lengths"
  end

  test "restores the snapshot created on the Wasm cache path" do
    @wasm = write_snapshot_fixture(@dir, :direct)
    out, err, status = run_snapshot(@cli, @dir, @wasm)
    assert_equal 3, status.exitstatus, err
    compile
    File.unlink(@wasm)
    restored, err, status = Open3.capture3({"WARDITE_TRACE" => "1"}, *@cli, "--snapshot", File.join(@dir, "snapshot"), "--", @artifact)
    assert_equal 3, status.exitstatus, err
    assert_include err, "snapshot restored:"
    assert_equal out, restored
  end
end
