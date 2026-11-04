# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require_relative "../support/efflorescence_helper"

class WarditeSpinelTest < Test::Unit::TestCase
  include EfflorescenceHelper
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @binary = ENV["WARDITE_SPINEL_BIN"]
    omit "Run make spinel-test to test the native executable" unless @binary
    assert File.executable?(@binary), "Native executable not found: #{@binary}"
  end

  test "Efflorescence opcode dispatch lowers to C switches" do
    Dir.mktmpdir("wardite-spinel-dispatch") do |dir|
      generated = File.join(dir, "wardite.c")
      output, status = Open3.capture2e(ENV.fetch("SPINEL", "spinel"), "--strict-require",
        "-I#{ROOT}/lib", "-c", "#{ROOT}/exe/wardite", "-o", generated)
      assert status.success?, output
      code = File.read(generated)
      %w[semantic flat].each do |name|
        body = code[/^static [^\n]+sp_(?:Wardite__Efflorescence__)?VM_execute_#{name}\([^;\n]*\) \{.*?(?=^static |\z)/m]
        assert_not_nil body, "Missing generated execute_#{name}"
        assert_match(/switch \(_t\d+/, body)
        assert_equal (0...Wardite::Efflorescence::Opcode::NAMES.size).to_a,
          body.scan(/^\s*case (\d+)LL:$/).flatten.map(&:to_i).sort,
          "execute_#{name} should dispatch every opcode through the literal switch"
        assert_match(/Frame \* lv_frame(?:__in)?, sp_PtrArray \* lv_pools/, body,
          "execute_#{name} must retain the concrete current frame and pool element types")
        assert_match(/sp_PtrArray \* lv_frames =/, body,
          "execute_#{name} must keep an unboxed frame stack")
        assert_not_match(/sp_PolyArray_(?:get|push|pop|new)/, body,
          "CALL/RETURN must not box the frame stack or call-site table")
        assert_not_match(/sp_pd_[a-f0-9]+\(/, body) if name == "flat"
        if name == "flat"
          assert_not_match(/\bsetjmp\(/, body,
            "flat dispatch must not install Kernel#loop's StopIteration handler")
          assert_not_match(/\bvolatile\b/, body,
            "flat dispatch must not need variables preserved across that handler")
          prelude = body.split(/^\s*case \d+LL:/, 2).first
          assert_equal 2, prelude.scan(/sp_IntArray\s*\*\s*\w+\s*=\s*lv_instructions\b/).size,
            "only opcode and a should be fetched before opcode dispatch"
        end
      end
      function_layout = code[/struct sp_Function(?:_s)? \{.*?^\};/m]
      assert_not_nil function_layout
      assert_match(/sp_PtrArray \* iv_calls;/, function_layout,
        "resolved call sites must stay a pointer array")
      transfer = code[/^static [^\n]+sp_CallSite_copy_arguments\([^;\n]*\) \{.*?(?=^static |\z)/m]
      assert_not_nil transfer
      assert_not_match(/sp_box_oint|sp_PolyArray_/, transfer,
        "argument transfer must stay unboxed and must not box an unused return value")
    end
  end

  test "i32.const with WASI disabled by default" do
    assert_native_result(<<~WAT, "answer", [], 42, no_wasi_flag: false)
      (module
        (func (export "answer") (result i32)
          i32.const 42))
    WAT
  end

  test "Efflorescence complete acceptance module on both native engines" do
    Dir.mktmpdir("wardite-spinel-mir") do |dir|
      wasm = File.join(dir, "mix.wasm")
      File.binwrite(wasm, compile_efflorescence_wat(File.read(MIX_WAT)))
      MIX_CASES.each do |rounds, seed|
        expected = reference_mix(rounds, seed)
        expected -= 2**32 if expected >= 2**31
        engine_options = [[], ["--new-engine"], ["--new-engine", "--mir-disable", "all"]]
        Wardite::Efflorescence::Configuration::FEATURES.each do |feature|
          engine_options << ["--new-engine", "--mir-disable", feature.to_s]
        end
        engine_options.each do |engine|
          %w[inline_mix call_mix].each do |export|
            out, err, status = Open3.capture3(@binary, *engine, "--invoke", export,
              "--", wasm, rounds.to_s, seed.to_s)
            assert status.success?, err
            assert_equal "", out
            assert_equal "return value: I32(#{expected})\n", err,
              "#{engine.inspect} #{export}(#{rounds}, #{seed})"
          end
        end
      end
    end
  end

  test "Efflorescence profiling and MIR dumps are opt in on native engine" do
    Dir.mktmpdir("wardite-spinel-mir-profile") do |dir|
      wasm = File.join(dir, "mix.wasm")
      File.binwrite(wasm, compile_efflorescence_wat(File.read(MIX_WAT)))
      out, err, status = Open3.capture3(@binary, "--new-engine", "--mir-dump", "--mir-profile",
        "--invoke", "call_mix", "--", wasm, "10", "123")
      assert status.success?, err
      assert_equal "", out
      assert_include err, "Semantic MIR (instructions=35 copies=11 registers=37)"
      assert_include err, "Optimized MIR (instructions=23 copies=2 registers=49)"
      assert_include err, "I32_XOR_SHR_U_IMM"
      assert_include err, "dispatches=73 copies=1 register_reads=63 register_writes=51 function_entries=1 frames_created=1"
      assert_include err, "return value: I32(483678737)"
    end
  end

  test "Efflorescence inlined leaves preserve argument snapshots and per-call local initialization" do
    Dir.mktmpdir("wardite-spinel-inline") do |dir|
      wasm = File.join(dir, "inline.wasm")
      File.binwrite(wasm, compile_efflorescence_wat(INLINE_WAT))
      [[], ["--mir-disable", "inline"], ["--mir-disable", "copy"],
       ["--mir-disable", "immediate"], ["--mir-disable", "flat"], ["--mir-profile"]].each do |options|
        [["snapshot", [0xffffffff], 0], ["snapshot", [123], 124], ["loop", [1000, 123], 123000],
         ["loop", [10, 0xffffffff], -10], ["constant", [], -1], ["void", [123], 123],
         ["branch", [0, 123], 99], ["branch", [1, 123], 123]].each do |name, arguments, expected|
          out, err, status = Open3.capture3(@binary, "--new-engine", *options,
            "--invoke", name, "--", wasm, *arguments.map(&:to_s))
          assert status.success?, err
          assert_equal "", out
          assert_include err, "return value: I32(#{expected})\n"
        end
      end
    end
  end

  test "Efflorescence reused native frames reinitialize local values" do
    code = <<~WAT
      (module
        (func $helper (param i32 i32) (result i32) (local i32)
          block
            local.get 0 i32.eqz br_if 0
            local.get 1 local.set 2
          end
          local.get 2)
        (func (export "run") (result i32)
          i32.const 1 i32.const 99 call $helper drop
          i32.const 0 i32.const 33 call $helper))
    WAT
    assert_native_result(code, "run", [], 0, new_engine: true)
  end

  test "Efflorescence snapshot and block result on native engine" do
    code = <<~WAT
      (module
        (func (export "snapshot") (param i32) (result i32)
          local.get 0
          block (result i32)
            i32.const 10 local.set 0
            i32.const 42 local.get 0 br_if 0
            drop i32.const 7
          end
          i32.add))
    WAT
    assert_native_result(code, "snapshot", [123], 165, new_engine: true)
  end

  test "Efflorescence selective initialization preserves reused joins constants and recursive locals" do
    Dir.mktmpdir("wardite-spinel-reset") do |dir|
      wasm = File.join(dir, "reset.wasm")
      File.binwrite(wasm, compile_efflorescence_wat(RESET_WAT))
      [[], ["--mir-disable", "all"], ["--mir-disable", "flat"],
       ["--mir-disable", "immediate"], ["--mir-profile"]].each do |options|
        [["run", 123, 15744], ["run", 0xffffffff, -128], ["recursive", 50, 2550]].each do |name, argument, expected|
          out, err, status = Open3.capture3(@binary, "--new-engine", *options,
            "--invoke", name, "--", wasm, argument.to_s)
          assert status.success?, err
          assert_equal "", out
          assert_include err, "return value: I32(#{expected})\n"
        end
      end
    end
  end

  test "Efflorescence arithmetic boundaries on native engine" do
    {"mul" => [[0xffffffff, 0xffffffff, 1], [0x80000000, 2, 0], [0x10001, 0x10001, 131073]],
     "add" => [[0xffffffff, 1, 0]], "sub" => [[0, 1, -1]],
     "shl" => [[0xffffffff, 31, -2147483648], [1, 32, 1], [1, -1, -2147483648]],
     "shr_u" => [[0xffffffff, 31, 1], [0xffffffff, 32, -1], [0x80000000, 33, 1073741824]]}.each do |op, cases|
      code = <<~WAT
        (module (func (export "run") (param i32 i32) (result i32)
          local.get 0 local.get 1 i32.#{op}))
      WAT
      cases.each { |a, b, expected| assert_native_result(code, "run", [a, b], expected, new_engine: true) }
    end
  end

  test "Efflorescence recursive calls use independent native frames" do
    code = <<~WAT
      (module
        (func $void)
        (func $count (export "count") (param i32) (result i32)
          block
            local.get 0 br_if 0
            i32.const 5 return
          end
          call $void
          local.get 0 i32.const 1 i32.sub call $count
          i32.const 1 i32.add))
    WAT
    assert_native_result(code, "count", [5000], 5005, new_engine: true)
  end

  test "Efflorescence call protocol preserves zero one multiple void and mutually recursive calls" do
    Dir.mktmpdir("wardite-spinel-call-protocol") do |dir|
      wasm = File.join(dir, "calls.wasm")
      File.binwrite(wasm, compile_efflorescence_wat(CALL_PROTOCOL_WAT))
      [[], ["--mir-disable", "inline"], ["--mir-disable", "all"], ["--mir-disable", "flat"],
       ["--mir-disable", "frames"], ["--mir-profile"]].each do |options|
        [["run", 0, -19], ["run", 123, 1247], ["run", 0xffffffff, -25],
         ["alias", 123, -1], ["mutual", 200, 20127]].each do |name, argument, expected|
          out, err, status = Open3.capture3(@binary, "--new-engine", *options,
            "--invoke", name, "--", wasm, argument.to_s)
          assert status.success?, err
          assert_equal "", out
          assert_include err, "return value: I32(#{expected})\n"
        end
      end
    end
  end

  test "Efflorescence zero through four argument calls and recursive transfers on native engine" do
    Dir.mktmpdir("wardite-spinel-arities") do |dir|
      loops = File.join(dir, "loops.wasm")
      edges = File.join(dir, "edges.wasm")
      File.binwrite(loops, compile_efflorescence_wat(File.read(ARITY_WAT)))
      File.binwrite(edges, compile_efflorescence_wat(ARITY_EDGE_WAT))
      [[], ["--mir-disable", "inline"], ["--mir-disable", "all"],
       ["--mir-disable", "inline", "--mir-disable", "flat"],
       ["--mir-disable", "inline", "--mir-disable", "frames"],
       ["--mir-disable", "inline", "--mir-profile"]].each do |options|
        cases = []
        {"call_zero" => 7, "call_one" => 0, "call_two" => 1, "call_three" => 3, "call_four" => 6}.each do |name, step|
          [[0, 123], [1, 0xffffffff], [1000, 0xffffffff]].each do |rounds, seed|
            cases << [loops, name, [rounds, seed], (seed + step * rounds) % (2**32)]
          end
        end
        cases += [[edges, "two", [200, 123], 20423], [edges, "three", [200, 123], 20823],
          [edges, "permuted", [17, 23, 31], 313], [edges, "duplicate", [0xffffffff], 0xfffffff7]]
        cases.each do |wasm, name, arguments, expected|
          expected -= 2**32 if expected >= 2**31
          out, err, status = Open3.capture3(@binary, "--new-engine", *options,
            "--invoke", name, "--", wasm, *arguments.map(&:to_s))
          assert status.success?, err
          assert_equal "", out
          assert_include err, "return value: I32(#{expected})\n", "#{options.inspect}, #{name}#{arguments}"
        end
      end
    end
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

  test "i64.div_s uses exact integer division and truncates toward zero" do
    [[0x7fffffffffffffff, 1, 0x7fffffffffffffff], [-9223372036854775808, 1, -9223372036854775808],
     [-7, 3, -2], [7, -3, -2], [-7, -3, 2]].each do |a, b, quotient|
      assert_native_result(<<~WAT, "div", [], 1)
        (module
          (func (export "div") (result i32)
            i64.const #{a}
            i64.const #{b}
            i64.div_s
            i64.const #{quotient}
            i64.eq))
      WAT
    end
  end

  test "signed division traps for minimum divided by minus one" do
    [32, 64].each do |bits|
      code = <<~WAT
        (module
          (func (export "div") (result i#{bits})
            i#{bits}.const #{-(1 << (bits - 1))}
            i#{bits}.const -1
            i#{bits}.div_s))
      WAT
      instance = Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code), enable_wasi: false)
      assert_raise(Wardite::IntegerOverflow) { instance.runtime.call("div", []) }
      Dir.mktmpdir("wardite-division-trap") do |dir|
        wasm = File.join(dir, "test.wasm")
        output, status = Open3.capture2e("wasm-tools", "parse", "-", "-o", wasm, stdin_data: code)
        assert status.success?, output
        _out, err, status = Open3.capture3(@binary, "--no-wasi", "--invoke", "div", "--", wasm)
        assert_false status.success?
        assert_include err, "integer overflow"
      end
    end
  end

  test "i64.ctz reaches the sign bit without constructing a wide mask" do
    [[0, 64], [-9223372036854775808, 63], [1, 0]].each do |value, count|
      assert_native_result(<<~WAT, "ctz", [], 1)
        (module
          (func (export "ctz") (result i32)
            i64.const #{value}
            i64.ctz
            i64.const #{count}
            i64.eq))
      WAT
    end
  end

  test "i64.popcnt counts the sign bit without constructing a wide mask" do
    [[0, 0], [-9223372036854775808, 1], [-1, 64], [0x5555555555555555, 32]].each do |value, count|
      assert_native_result(<<~WAT, "popcnt", [], 1)
        (module
          (func (export "popcnt") (result i32)
            i64.const #{value}
            i64.popcnt
            i64.const #{count}
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

  test "floating-point truncation compiles without a global overflow mode" do
    Dir.mktmpdir("wardite-float-truncation") do |dir|
      executable = File.join(dir, "truncate")
      output, status = Open3.capture2e(
        ENV.fetch("SPINEL", "spinel"), "--strict-require", "-I#{ROOT}/lib",
        "#{ROOT}/test/spinel/float_truncation.rb", "-o", executable
      )
      assert status.success?, output
      stdout, stderr, status = Open3.capture3(executable)
      assert status.success?, stderr
      assert_equal <<~OUTPUT, stdout
        9223372036854775808
        18446744073709551615
        0
        4294967295
        18446744073709549568
        18446744073709551615
        9223372036854775807
        -9223372036854775808
        9223372036854775807
        -9223372036854775808
      OUTPUT
    end
  end

  private

  def assert_native_result(code, export, args, expected, no_wasi_flag: true, new_engine: false)
    Dir.mktmpdir("wardite-spinel-test") do |dir|
      wat = File.join(dir, "test.wat")
      wasm = File.join(dir, "test.wasm")
      File.write(wat, code)
      output, status = Open3.capture2e("wasm-tools", "parse", wat, "-o", wasm)
      assert status.success?, output

      arguments = ["--invoke", export, "--", wasm, *args.map(&:to_s)]
      arguments.unshift("--new-engine") if new_engine
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
