# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class WarditeSpinelTest < Test::Unit::TestCase
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @binary = ENV["WARDITE_SPINEL_BIN"]
    omit "Run make spinel-test to test the native executable" unless @binary
    assert File.executable?(@binary), "Native executable not found: #{@binary}"
  end

  test "i32.const with WASI disabled by default" do
    assert_native_result(<<~WAT, "answer", [], 42, no_wasi_flag: false)
      (module
        (func (export "answer") (result i32)
          i32.const 42))
    WAT
  end

  test "i32.add with runtime arguments and wrapping" do
    code = <<~WAT
      (module
        (func (export "add") (param i32 i32) (result i32)
          local.get 0
          local.get 1
          i32.add))
    WAT
    assert_native_result(code, "add", [100, 200], 300)
    assert_native_result(code, "add", [7, -9], -2)
    assert_native_result(code, "add", [2147483647, 1], -2147483648)
  end

  test "internal call" do
    assert_native_result(<<~WAT, "double", [123], 246)
      (module
        (func $double (param i32) (result i32)
          local.get 0
          local.get 0
          i32.add)
        (func (export "double") (param i32) (result i32)
          local.get 0
          call $double))
    WAT
  end

  test "if and else keep their decoded branch positions" do
    code = <<~WAT
      (module
        (func (export "choose") (param i32) (result i32)
          local.get 0
          if (result i32)
            i32.const 42
          else
            i32.const 7
          end))
    WAT
    assert_native_result(code, "choose", [0], 7)
    assert_native_result(code, "choose", [1], 42)
  end

  test "indirect calls use element index vectors" do
    code = <<~WAT
      (module
        (type $result (func (result i32)))
        (table 2 funcref)
        (elem (i32.const 0) $first $second)
        (func $first (result i32) i32.const 111)
        (func $second (result i32) i32.const 222)
        (func (export "choose") (param i32) (result i32)
          local.get 0
          call_indirect (type $result)))
    WAT
    assert_native_result(code, "choose", [0], 111)
    assert_native_result(code, "choose", [1], 222)
  end

  test "i64 arithmetic keeps overflowing intermediate values before masking" do
    assert_native_result(<<~WAT, "overflow", [], 1)
      (module
        (func (export "overflow") (result i32)
          i64.const 4294967296
          i64.const 4294967296
          i64.mul
          i64.eqz))
    WAT
  end

  private

  def assert_native_result(code, export, args, expected, no_wasi_flag: true)
    Dir.mktmpdir("wardite-spinel-test") do |dir|
      wat = File.join(dir, "test.wat")
      wasm = File.join(dir, "test.wasm")
      File.write(wat, code)
      output, status = Open3.capture2e("wasm-tools", "parse", wat, "-o", wasm)
      assert status.success?, output

      arguments = ["--invoke", export, "--", wasm, *args.map(&:to_s)]
      native_arguments = no_wasi_flag ? ["--no-wasi", *arguments] : arguments
      stdout, stderr, status = Open3.capture3(@binary, *native_arguments)
      assert status.success?, stderr
      assert_equal "", stdout
      assert_equal "return value: I32(#{expected})\n", stderr

      # Compare with the same CLI on CRuby; it also runs without WASI.
      ruby_out, ruby_err, ruby_status = Open3.capture3(
        RbConfig.ruby, "-I#{ROOT}/lib", "#{ROOT}/exe/wardite",
        "--no-wasi", *arguments
      )
      assert ruby_status.success?, ruby_err
      assert_equal ruby_out, stdout
      assert_equal ruby_err, stderr
    end
  end
end
