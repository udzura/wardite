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

  test "i64.mul wraps at the unsigned and signed boundaries" do
    [[-1, -1, 1], [0x7fffffffffffffff, 2, -2], [-9223372036854775808, 2, 0]].each do |a, b, product|
      assert_native_result(<<~WAT, "mul", [], 1)
        (module
          (func (export "mul") (result i32)
            i64.const #{a}
            i64.const #{b}
            i64.mul
            i64.const #{product}
            i64.eq))
      WAT
    end
  end

  test "i64.add carries into and beyond the sign bit" do
    [[0x7fffffffffffffff, 1, -9223372036854775808], [-1, 1, 0], [0xffffffff, 1, 0x100000000]].each do |a, b, sum|
      assert_native_result(<<~WAT, "add", [], 1)
        (module
          (func (export "add") (result i32)
            i64.const #{a}
            i64.const #{b}
            i64.add
            i64.const #{sum}
            i64.eq))
      WAT
    end
  end

  test "i64.shl masks the count and discards overflowing bits" do
    [[1, 63, -9223372036854775808], [-1, 1, -2], [-1, 64, -1], [1, -1, -9223372036854775808]].each do |a, b, shifted|
      assert_native_result(<<~WAT, "shl", [], 1)
        (module
          (func (export "shl") (result i32)
            i64.const #{a}
            i64.const #{b}
            i64.shl
            i64.const #{shifted}
            i64.eq))
      WAT
    end
  end

  test "i64.rotl rotates across the sign bit without wide intermediates" do
    [[-9223372036854775807, 1, 3], [1, 63, -9223372036854775808], [-1, 0, -1], [1, 64, 1]].each do |a, b, rotated|
      assert_native_result(<<~WAT, "rotl", [], 1)
        (module
          (func (export "rotl") (result i32)
            i64.const #{a}
            i64.const #{b}
            i64.rotl
            i64.const #{rotated}
            i64.eq))
      WAT
    end
  end

  test "i64.rotr rotates into the sign bit without wide intermediates" do
    [[1, 1, -9223372036854775808], [-9223372036854775808, 63, 1], [-1, 0, -1], [1, 64, 1]].each do |a, b, rotated|
      assert_native_result(<<~WAT, "rotr", [], 1)
        (module
          (func (export "rotr") (result i32)
            i64.const #{a}
            i64.const #{b}
            i64.rotr
            i64.const #{rotated}
            i64.eq))
      WAT
    end
  end

  test "I32 normalization compiles without a global overflow mode" do
    Dir.mktmpdir("wardite-i32-normalization") do |dir|
      executable = File.join(dir, "normalize")
      output, status = Open3.capture2e(
        ENV.fetch("SPINEL", "spinel"), "--strict-require", "-I#{ROOT}/lib",
        "#{ROOT}/test/spinel/i32_normalization.rb", "-o", executable
      )
      assert status.success?, output
      stdout, stderr, status = Open3.capture3(executable)
      assert status.success?, stderr
      assert_equal "42\n4294967295\n", stdout
    end
  end

  test "i32.mul wraps unsigned operand products" do
    code = <<~WAT
      (module
        (func (export "mul") (param i32 i32) (result i32)
          local.get 0
          local.get 1
          i32.mul))
    WAT
    assert_native_result(code, "mul", [0xffffffff, 0xffffffff], 1)
    assert_native_result(code, "mul", [0x80000000, 2], 0)
    assert_native_result(code, "mul", [0x10001, 0x10001], 131073)
  end

  test "i32.rotl avoids a mask wider than 64 bits" do
    code = <<~WAT
      (module
        (func (export "rotl") (param i32 i32) (result i32)
          local.get 0
          local.get 1
          i32.rotl))
    WAT
    assert_native_result(code, "rotl", [0x80000001, 1], 3)
    assert_native_result(code, "rotl", [0xffffffff, 0], -1)
    assert_native_result(code, "rotl", [1, 31], -2147483648)
    assert_native_result(code, "rotl", [0x80000001, 32], -2147483647)
  end

  test "I32 multiplication compiles without a global overflow mode" do
    Dir.mktmpdir("wardite-i32-multiply") do |dir|
      executable = File.join(dir, "multiply")
      output, status = Open3.capture2e(
        ENV.fetch("SPINEL", "spinel"), "--strict-require", "-I#{ROOT}/lib",
        "#{ROOT}/test/spinel/i32_multiply.rb", "-o", executable
      )
      assert status.success?, output
      stdout, stderr, status = Open3.capture3(executable)
      assert status.success?, stderr
      assert_equal "1\n0\n131073\n", stdout
    end
  end

  test "i64 signed comparison handles the minimum value" do
    assert_native_result(<<~WAT, "signed_min", [], 1)
      (module
        (func (export "signed_min") (result i32)
          i64.const -9223372036854775808
          i64.const 0
          i64.lt_s))
    WAT
  end

  test "signed LEB128 compiles without a global overflow mode" do
    Dir.mktmpdir("wardite-sleb128") do |dir|
      executable = File.join(dir, "sleb128")
      output, status = Open3.capture2e(
        ENV.fetch("SPINEL", "spinel"), "--strict-require", "-I#{ROOT}/lib",
        "#{ROOT}/test/spinel/sleb128.rb", "-o", executable
      )
      assert status.success?, output
      stdout, stderr, status = Open3.capture3(executable)
      assert status.success?, stderr
      assert_equal "9223372036854775807\n-9223372036854775808\n-1\n", stdout
    end
  end

  test "I64 normalization compiles without a global overflow mode" do
    Dir.mktmpdir("wardite-i64-normalization") do |dir|
      executable = File.join(dir, "normalize")
      output, status = Open3.capture2e(
        ENV.fetch("SPINEL", "spinel"), "--strict-require", "-I#{ROOT}/lib",
        "#{ROOT}/test/spinel/i64_normalization.rb", "-o", executable
      )
      assert status.success?, output
      stdout, stderr, status = Open3.capture3(executable)
      assert status.success?, stderr
      expected = [9223372036854775807, 9223372036854775808, 18446744073709551615,
                  18446744073709551615, 42, 18446744073709551615]
      assert_equal expected.map { |n| "#{n}\n" }.join, stdout
    end
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
