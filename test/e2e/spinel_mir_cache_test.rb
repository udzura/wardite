# frozen_string_literal: true

require "test_helper"
require_relative "../support/efflorescence_helper"

class WarditeSpinelMIRCacheTest < Test::Unit::TestCase
  include EfflorescenceHelper

  def setup
    @binary = ENV["WARDITE_SPINEL_BIN"]
    omit "Run make spinel-test to test the native executable" unless @binary
  end

  test "Spinel help lists the MIR cache option" do
    stdout, stderr, status = Open3.capture3(@binary, "--help")
    assert status.success?, stderr
    assert_include stdout, "--mir-cache DIR"
  end

  test "Spinel hits its own cache across processes and rebuilds a truncated entry" do
    wasm = File.expand_path("../add.wasm", __dir__)
    Dir.mktmpdir do |cache|
      args = ["--invoke", "add", "--", wasm, "20", "22"]
      assert_cached_call(cache, "miss", "I32(42)", *args)
      assert_cached_call(cache, "hit", "I32(42)", *args)
      path = Dir.glob(File.join(cache, "*.mir2")).fetch(0)
      original = File.binread(path)
      File.truncate(path, original.bytesize - 1)
      assert_cached_call(cache, "miss", "I32(42)", *args)
      assert_equal original, File.binread(path)
      assert_cached_call(cache, "hit", "I32(42)", *args)
      assert_equal [File.basename(path)], Dir.children(cache)
    end
  end

  test "Spinel restores exception handlers and signed float and integer carriers" do
    fixture = File.expand_path("../fixtures/efflorescence/m5_store_eh.wat", __dir__)
    Dir.mktmpdir do |directory|
      wasm = File.join(directory, "exceptions.wasm")
      File.binwrite(wasm, compile_efflorescence_wat(File.read(fixture)))
      cache = File.join(directory, "cache")
      args = ["--invoke", "repeat_eh", "--", wasm]
      assert_cached_call(cache, "miss", "I32(1)", *args)
      assert_cached_call(cache, "hit", "I32(1)", *args)
    end
  end

  private

  def assert_cached_call(cache, state, result, *args)
    stdout, stderr, status = Open3.capture3({"WARITE_TRACE" => "1"}, @binary,
      "--new-engine", "--no-wasi", "--mir-cache", cache, *args)
    assert status.success?, stderr
    assert_empty stdout
    assert_include stderr, "MIR2 cache #{state}:"
    assert_include stderr, "return value: #{result}"
  end
end
