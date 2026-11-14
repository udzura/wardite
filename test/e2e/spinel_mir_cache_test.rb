# frozen_string_literal: true

require "test_helper"
require "digest"
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
    assert_include stdout, "--mir-cache-verify MODE"
    assert_include stdout, "--mir-cache-eager"
  end

  test "Spinel hits its own cache across processes and rebuilds a truncated entry" do
    wasm = File.expand_path("../add.wasm", __dir__)
    Dir.mktmpdir do |cache|
      args = ["--invoke", "add", "--", wasm, "20", "22"]
      assert_cached_call(cache, "miss", "I32(42)", *args)
      assert_cached_call(cache, "hit", "I32(42)", *args)
      assert_cached_call(cache, "hit", "I32(42)", "--mir-cache-verify", "sha256", *args)
      path = Dir.glob(File.join(cache, "*.mir2")).fetch(0)
      original = File.binread(path)
      File.truncate(path, original.bytesize - 1)
      assert_cached_call(cache, "miss", "I32(42)", *args)
      assert_equal original, File.binread(path)
      assert_cached_call(cache, "hit", "I32(42)", *args)
      assert_equal [File.basename(path)], Dir.children(cache)
    end
  end

  test "CRuby and Spinel write the same integrity fields and defer unsampled function errors" do
    Dir.mktmpdir do |directory|
      wasm = File.join(directory, "identity.wasm")
      mib = 1024 * 1024
      bad_index = 1200
      identity = "(func (param i32) (result i32) local.get 0)\n"
      wat = "(module (func (export \"value\") (param i32) (result i32) local.get 0)\n" +
        identity * (bad_index - 1) + "(func (export \"bad\") (param i32) (result i32) local.get 0)\n" +
        identity * (12_000 - bad_index) + ")"
      bytes = compile_efflorescence_wat(wat)
      File.binwrite(wasm, bytes)
      args = ["--invoke", "value", "--", wasm, "42"]
      cruby_cache = File.join(directory, "cruby")
      cruby = Wardite.new(buffer: StringIO.new(bytes), engine: :efflorescence, mir_cache: cruby_cache).runtime
      cache = File.join(directory, "native")
      assert_cached_call(cache, "miss", "I32(42)", "--mir-cache-verify", "sha256", *args)
      assert_cached_call(cache, "hit", "I32(42)", *args)

      path = Dir.glob(File.join(cache, "*.mir2")).fetch(0)
      original = File.binread(path)
      cruby_file = File.binread(Dir.glob(File.join(cruby_cache, "*.mir2")).fetch(0))
      payload = original.byteslice(120..)
      assert_operator payload.bytesize, :>, mib + 4096
      assert_operator payload.bytesize, :<, 2 * mib
      assert_equal cruby_file.byteslice(48..), original.byteslice(48..)
      length = [payload.bytesize].pack("Q<")
      assert_equal length, original.byteslice(48, 8)
      sample = length + payload.byteslice(0, 65536) + payload.byteslice(mib, 4096) + payload.byteslice(-65536..)
      assert_equal Digest::SHA256.digest(sample), original.byteslice(56, 32)
      assert_equal Digest::SHA256.digest(payload), original.byteslice(88, 32)

      bytecode = cruby.ir.functions.fetch(bad_index).bytecode.pack("q<*")
      record, size = original.unpack("l<2", offset: 124 + 8 * bad_index)
      code = original.index(bytecode, 120 + record)
      assert_not_nil code
      assert_operator code, :>=, 120 + 65536
      assert_operator code + bytecode.bytesize, :<=, 120 + record + size
      assert_operator code + bytecode.bytesize, :<, 120 + mib
      assert_operator code + bytecode.bytesize, :<, original.bytesize - 65536
      %w[sha256 checksum].each do |mode|
        [120, 120 + mib].each do |offset|
          corrupt = original.dup
          corrupt.setbyte(offset, corrupt.getbyte(offset) ^ 1)
          File.binwrite(path, corrupt)
          assert_cached_call(cache, "miss", "I32(42)", "--mir-cache-verify", mode, *args)
          assert_equal original, File.binread(path)
        end

        # The first word is the opcode and the second is the result register.
        [code, code + 8].each do |offset|
          corrupt = original.dup
          corrupt.setbyte(offset, 255)
          File.binwrite(path, corrupt)
          if mode == "checksum"
            assert_cached_call(cache, "hit", "I32(42)", *args)
            _stdout, stderr, status = Open3.capture3({"WARDITE_TRACE" => "1"}, @binary,
              "--new-engine", "--no-wasi", "--mir-cache", cache, "--invoke", "bad", "--", wasm, "42")
            assert_false status.success?
            assert_include stderr, "MIR2 cache hit:"
            assert_include stderr, "invalid MIR2 function #{bad_index} in #{path}"
            assert_equal corrupt, File.binread(path)
            assert_cached_call(cache, "miss", "I32(42)", "--mir-cache-eager", *args)
          else
            assert_cached_call(cache, "miss", "I32(42)", "--mir-cache-verify", mode, *args)
          end
          assert_equal original, File.binread(path)
        end
      end
    end
  end

  test "Spinel rejects an unknown verification mode" do
    _stdout, stderr, status = Open3.capture3(@binary, "--mir-cache-verify", "unknown", "unused.wasm")
    assert_false status.success?
    assert_include stderr, "--mir-cache-verify expects checksum or sha256"
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
    stdout, stderr, status = Open3.capture3({"WARDITE_TRACE" => "1"}, @binary,
      "--new-engine", "--no-wasi", "--mir-cache", cache, *args)
    assert status.success?, stderr
    assert_empty stdout
    assert_include stderr, "MIR2 cache #{state}:"
    assert_include stderr, "return value: #{result}"
  end
end
