# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"
require "wardite/cli/cli"
require "rbconfig"

class EfflorescenceTest < Test::Unit::TestCase
  include EfflorescenceHelper

  test "complete acceptance module agrees with both engines and independent reference" do
    bytes = compile_efflorescence_wat(File.read(MIX_WAT))
    old = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false)
    new = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false, engine: :efflorescence)
    assert_instance_of Wardite::Runtime, old.runtime
    assert_instance_of Wardite::Efflorescence::VM, new.runtime
    MIX_CASES.each do |rounds, seed|
      expected = reference_mix(rounds, seed)
      [old, new].each do |instance|
        %w[inline_mix call_mix].each do |export|
          assert_equal expected, instance.runtime.call(export, [rounds, seed]).value,
            "#{instance.runtime.class} #{export}(#{rounds}, #{seed})"
        end
      end
    end
    random = Random.new(123)
    20.times do
      rounds = random.rand(0..50)
      seed = random.rand(0..0xffffffff)
      %w[inline_mix call_mix].each do |export|
        assert_equal reference_mix(rounds, seed), new.runtime.call_unboxed(export, [rounds, seed])
      end
    end
  end

  test "constants and local gets become register sources" do
    instance = load_efflorescence(<<~WAT)
      (module (func (export "add") (param i32) (result i32)
        local.get 0 i32.const 10 i32.add))
    WAT
    function = instance.runtime.semantic_ir.functions[0]
    assert_equal 0, function.index
    assert_equal [:i32], function.parameter_types
    assert_equal [:i32], function.result_types
    assert_equal 0, function.local_count
    assert_equal function.initial_registers.size, function.register_count
    assert_include function.initial_registers, 10
    assert_equal [Wardite::Efflorescence::Opcode::I32_ADD,
                  Wardite::Efflorescence::Opcode::COPY,
                  Wardite::Efflorescence::Opcode::RETURN], function.instructions.map { |insn| insn[0] }
    assert function.instructions.flat_map(&:operands).all? { |value| value.is_a?(Integer) }
    assert_equal 52, instance.runtime.add(42).value
    assert instance.runtime.respond_to?(:add)
    assert_equal 10, instance.add(0).value
  end

  test "local get snapshots survive set and tee" do
    instance = load_efflorescence(<<~WAT)
      (module
        (func (export "set") (param i32) (result i32)
          local.get 0 i32.const 10 local.set 0 i32.const 1 i32.add)
        (func (export "tee") (param i32) (result i32)
          local.get 0 i32.const 10 local.tee 0 i32.add))
    WAT
    assert_equal 124, instance.set(123).value
    assert_equal 133, instance.tee(123).value
  end

  test "stack prefix snapshots survive conditional edges and loop backedges" do
    instance = load_efflorescence(<<~WAT)
      (module
        (func (export "prefix") (param i32 i32) (result i32)
          local.get 0
          block
            local.get 1 br_if 0
            i32.const 99 local.set 0
          end
          local.get 0 i32.add)
        (func (export "loop_prefix") (param i32 i32) (result i32)
          local.get 0
          block $done
            loop $repeat
              local.get 1 i32.eqz br_if $done
              local.get 0 i32.const 1 i32.add local.set 0
              local.get 1 i32.const 1 i32.sub local.set 1
              br $repeat
            end
          end
          local.get 0 i32.add))
    WAT
    assert_equal 106, instance.prefix(7, 0).value
    assert_equal 14, instance.prefix(7, 1).value
    assert_equal 24, instance.loop_prefix(7, 10).value
    assert_equal 14, instance.loop_prefix(7, 0).value
  end

  test "branch results, discarded values, function labels and dead code" do
    instance = load_efflorescence(<<~WAT)
      (module
        (func (export "choose") (param i32) (result i32)
          block (result i32)
            i32.const 42 local.get 0 br_if 0
            drop i32.const 7
          end)
        (func (export "nested") (result i32)
          block (result i32)
            i32.const 999
            block
              i32.const 777 i32.const 55 br 1
              i32.add drop
            end
            drop i32.const 1
          end)
        (func (export "label") (result i32)
          i32.const 123 br 0 i32.add)
        (func (export "loop_result") (param i32) (result i32)
          loop (result i32)
            local.get 0 i32.const 1 i32.sub local.tee 0 br_if 0
            i32.const 77
          end))
    WAT
    assert_equal 7, instance.choose(0).value
    assert_equal 42, instance.choose(1).value
    assert_equal 55, instance.nested.value
    assert_equal 123, instance.label.value
    assert_equal 77, instance.loop_result(3).value
  end

  test "internal frames handle recursion and void calls without Ruby recursion" do
    instance = load_efflorescence(<<~WAT)
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
    assert_equal 5005, instance.count(5000).value
    assert_equal 5, instance.count(0).value
  end

  test "i32 normalization wrapping shift counts and unsigned products" do
    %w[add sub mul xor shl shr_u].each do |op|
      instance = load_efflorescence(<<~WAT)
        (module (func (export "run") (param i32 i32) (result i32)
          local.get 0 local.get 1 i32.#{op}))
      WAT
      [[-1, -1], [0xffffffff, 0xffffffff], [0x80000000, 2], [0x10001, 0x10001],
       [0xffffffff, 31], [0xffffffff, 32], [0xffffffff, 33], [0x80000001, 63]].each do |a, b|
        left, right = a & 0xffffffff, b & 0xffffffff
        expected = case op
        when "add" then left + right
        when "sub" then left - right
        when "mul" then left * right
        when "xor" then left ^ right
        when "shl" then left << (right % 32)
        when "shr_u" then left >> (right % 32)
        end
        assert_equal expected & 0xffffffff, instance.run(a, b).value, "#{op}(#{a}, #{b})"
      end
    end
    identity = load_efflorescence('(module (func (export "id") (param i32) (result i32) local.get 0))')
    [-1, 0x100000001, -(2**80)].each { |value| assert_equal value & 0xffffffff, identity.id(value).value }
  end

  test "only Ruby return boundary boxes i32 and Runtime never executes" do
    instance = load_efflorescence(File.read(MIX_WAT))
    boxes = 0
    runtime_calls = 0
    frames = 0
    trace = TracePoint.new(:call) do |event|
      boxes += 1 if event.defined_class == Wardite::I32 && event.method_id == :initialize
      runtime_calls += 1 if event.defined_class == Wardite::Runtime
      if event.defined_class == Wardite::Efflorescence::Frame && event.method_id == :initialize
        frames += 1
      end
    end
    result = trace.enable { instance.runtime.call("call_mix", [1000, 123]) }
    assert_equal reference_mix(1000, 123), result.value
    assert_equal 1, boxes
    assert_equal 0, runtime_calls
    assert_equal 2, frames
    assert instance.runtime.ir.functions.all? { |fn| fn.initial_registers.all? { |v| v.is_a?(Integer) } }
  end

  test "start function is run by selected engine" do
    bytes = compile_efflorescence_wat('(module (func $start unreachable) (start $start))')
    calls = 0
    trace = TracePoint.new(:call) { |event| calls += 1 if event.defined_class == Wardite::Runtime }
    assert_raise(Wardite::Unreachable) do
      trace.enable do
        Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false, engine: :efflorescence)
      end
    end
    assert_equal 0, calls
  end

  test "public argument export and void return behavior" do
    instance = load_efflorescence(<<~WAT)
      (module (memory (export "memory") 1)
        (func (export "void"))
        (func (export "id") (param i32) (result i32) local.get 0))
    WAT
    assert_nil instance.void
    assert_false instance.runtime.callable?(:memory)
    assert_raise(NoMethodError) { instance.runtime.call(:memory, []) }
    assert_raise(NoMethodError) { instance.runtime.call(:missing, []) }
    assert_raise(Wardite::ArgumentError) { instance.runtime.call(:id, []) }
    assert_raise(Wardite::ArgumentError) { instance.runtime.call(:id, [1.5]) }
  end

  test "unsupported features fail explicitly even in dead or unexported functions" do
    ['(module (func (export "f") (result i64) i64.const 1))',
     '(module (func (export "f") unreachable i32.const 1 i32.const 1 i32.and drop))',
     '(module (func (export "f")) (func (local f64)))',
     '(module (import "host" "function" (func)))',
     '(module (func (export "f") i32.const 1 if nop end))',
     '(module (func (export "f") block (result f64) f64.const 1 end drop))'].each do |wat|
      error = assert_raise(Wardite::Efflorescence::UnsupportedFeature) { load_efflorescence(wat) }
      assert_include error.message, "Efflorescence"
    end
  end

  test "unsupported CLI instructions never fall back to stack VM" do
    Dir.mktmpdir("wardite-efflorescence-unsupported") do |dir|
      file = File.join(dir, "unsupported.wasm")
      File.binwrite(file, compile_efflorescence_wat(<<~WAT))
        (module (func (export "run") (result i32)
          i32.const 3 i32.const 1 i32.and))
      WAT
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{File.expand_path('../lib', __dir__)}",
        File.expand_path("../exe/wardite", __dir__), "--new-engine", "--no-wasi", "--invoke", "run", file)
      assert_false status.success?
      assert_equal "", stdout
      assert_include stderr, "unsupported instruction i32_and"
    end
  end

  test "CLI selects new engine and keeps default output and errors" do
    Dir.mktmpdir("wardite-efflorescence-cli") do |dir|
      file = File.join(dir, "mix.wasm")
      File.binwrite(file, compile_efflorescence_wat(File.read(MIX_WAT)))
      [[], ["--new-engine"]].each do |options|
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{File.expand_path('../lib', __dir__)}",
          File.expand_path("../exe/wardite", __dir__), *options,
          "--no-wasi", "--invoke", "call_mix", "--", file, "1", "123")
        assert status.success?, stderr
        assert_equal "", stdout
        signed = reference_mix(1, 123)
        signed -= 2**32 if signed >= 2**31
        assert_equal "return value: I32(#{signed})\n", stderr
      end
      assert_instance_of Wardite::Runtime, Wardite::Cli::Cli.new(["--no-wasi", file]).new_instance.runtime
      assert_instance_of Wardite::Efflorescence::VM,
        Wardite::Cli::Cli.new(["--new-engine", "--no-wasi", file]).new_instance.runtime
    end
  end
end
