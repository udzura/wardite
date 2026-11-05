# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"
require "wardite/cli/cli"

class EfflorescenceOptimizerTest < Test::Unit::TestCase
  include EfflorescenceHelper
  E = Wardite::Efflorescence
  OP = E::Opcode

  def configurations
    [[], [:all], *E::Configuration::FEATURES.map { |feature| [feature] }]
  end

  test "dispatch labels are integer literals synchronized with opcode definitions" do
    source = File.read(File.expand_path("../lib/wardite/efflorescence/vm.rb", __dir__))
    methods = source.split(/^      def execute_flat\(frame, pools, active_frames\)$/).drop(1)
    assert_equal 1, methods.size
    methods.each do |body|
      labels = body.scan(/^          when (\d+) # Opcode::([A-Z_0-9]+)$/)
      assert_equal OP::NAMES.sort, labels.map(&:last).sort
      labels.each do |number, name|
        assert_equal OP.const_get(name), Integer(number), "dispatch literal for #{name}"
      end
    end
  end

  test "every configuration lowers to flat bytecode including unoptimized profiling" do
    bytes = compile_efflorescence_wat(File.read(MIX_WAT))
    [[], [:all]].product([false, true]).each do |disabled, profile|
      vm = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false,
        engine: :efflorescence, disabled_optimizations: disabled, mir_profile: profile).runtime
      assert_false vm.respond_to?(:execute_semantic, true)
      vm.ir.functions.each do |function|
        assert_equal E::Lowerer::WIDTH * function.instructions.size, function.bytecode.size
      end
      assert_equal reference_mix(10, 123), vm.call_unboxed("call_mix", [10, 123])
    end
    assert_not_include E::Configuration::FEATURES, :flat
    error = assert_raise(Wardite::ArgumentError) { E::Configuration.new([:flat]) }
    assert_include error.message, "unknown MIR optimization: flat"
  end

  test "all acceptance inputs with each optimization independently disabled" do
    bytes = compile_efflorescence_wat(File.read(MIX_WAT))
    configurations.each do |disabled|
      instance = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false,
        engine: :efflorescence, disabled_optimizations: disabled)
      MIX_CASES.each do |rounds, seed|
        %w[inline_mix call_mix].each do |export|
          assert_equal reference_mix(rounds, seed), instance.runtime.call_unboxed(export, [rounds, seed]),
            "#{disabled.inspect} #{export}(#{rounds}, #{seed})"
        end
      end
    end
  end

  test "passes preserve input MIR and reduce dispatches and copies" do
    instance = load_efflorescence(File.read(MIX_WAT))
    vm = instance.runtime
    assert_equal [9, 16, 10], vm.semantic_ir.functions.map { |fn| fn.instructions.size }
    assert_equal [5, 9, 9], vm.optimized_ir.functions.map { |fn| fn.instructions.size }
    assert_equal [2, 5, 4], vm.semantic_ir.functions.map { |fn| fn.instructions.count { |i| i[0] == OP::COPY } }
    assert_include vm.dump_mir, "I32_XOR_SHR_U_IMM"
    assert_include vm.dump_mir, "I32_MUL_IMM"
    assert_include vm.dump_mir, "BR_IF_ZERO"
    vm.ir.functions.each do |function|
      assert_equal 4 * function.instructions.size, function.bytecode.size
      assert function.bytecode.all? { |operand| operand.is_a?(Integer) }
      function.instructions.each_with_index do |instruction, pc|
        position = OP.target_position(instruction)
        assert_equal instruction[position] * 4, function.bytecode[pc * 4 + position] if position >= 0
      end
      function.calls.each_with_index do |site, index|
        assert_same site, function.call_site(index)
        assert_same vm.ir.function_at(site.callee.index), site.callee
      end
    end
    assert_equal 0, vm.metrics.dispatches
    assert vm.ir.functions.none? { |fn| fn.instructions.any? { |i| i[0] == OP::PROFILE } }
  end

  test "instruction and register access counters are separate from ordinary execution" do
    bytes = compile_efflorescence_wat(File.read(MIX_WAT))
    [[], [:all], [:inline]].each do |disabled|
      vm = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false,
        engine: :efflorescence, disabled_optimizations: disabled, mir_profile: true).runtime
      %w[inline_mix call_mix].each do |export|
        assert_equal reference_mix(10, 123), vm.call_unboxed(export, [10, 123])
        inline = export == "inline_mix"
        optimized = disabled != [:all]
        expanded = optimized && disabled != [:inline]
        dispatches = optimized ? (inline || expanded ? 73 : 93) : (inline ? 135 : 165)
        assert_equal dispatches, vm.metrics.dispatches
        assert_equal optimized ? 1 : (inline ? 32 : 42), vm.metrics.copies
        assert_equal inline || expanded ? 1 : (optimized ? 2 : 11), vm.metrics.frames_created
        assert_equal inline || expanded ? 1 : 11, vm.metrics.function_entries
        if optimized
          assert_equal inline || expanded ? 63 : 83, vm.metrics.register_reads
          assert_equal inline || expanded ? 51 : 71, vm.metrics.register_writes
        end
      end
    end
  end

  test "copy propagation preserves snapshots across writes edges calls and loops" do
    wat = <<~WAT
      (module
        (func $identity (param i32) (result i32) local.get 0)
        (func (export "snapshot") (param i32 i32) (result i32)
          local.get 0
          i32.const 10 local.set 0
          block
            local.get 1 br_if 0
            i32.const 20 local.tee 0 drop
          end
          local.get 0 call $identity i32.add)
        (func (export "loop") (param i32 i32) (result i32)
          local.get 0
          block $done
            loop $repeat
              local.get 1 i32.eqz br_if $done
              local.get 0 i32.const 1 i32.add local.set 0
              local.get 1 i32.const 1 i32.sub local.set 1
              br $repeat
            end
          end
          local.get 0 i32.add)
        (func (export "result") (param i32) (result i32)
          block (result i32)
            i32.const 42 local.get 0 br_if 0
            drop i32.const 7
          end))
    WAT
    bytes = compile_efflorescence_wat(wat)
    configurations.each do |disabled|
      vm = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false,
        engine: :efflorescence, disabled_optimizations: disabled).runtime
      assert_equal 143, vm.call_unboxed("snapshot", [123, 0]), disabled.inspect
      assert_equal 133, vm.call_unboxed("snapshot", [123, 1]), disabled.inspect
      assert_equal 24, vm.call_unboxed("loop", [7, 10]), disabled.inspect
      assert_equal 14, vm.call_unboxed("loop", [7, 0]), disabled.inspect
      assert_equal 7, vm.call_unboxed("result", [0]), disabled.inspect
      assert_equal 42, vm.call_unboxed("result", [1]), disabled.inspect
    end
  end

  test "peepholes cannot absorb an instruction with an incoming edge" do
    function = E::Function.new(0, [:i32, :i32], [:i32], 0)
    temporary = function.allocate_register(42)
    function.replace_instructions([
      E::Instruction.new([OP::BR_IF, 0, 2]),
      E::Instruction.new([OP::I32_ADD, temporary, 1, 1]),
      E::Instruction.new([OP::COPY, 1, temporary]),
      E::Instruction.new([OP::RETURN, 1])
    ])
    E::Passes::CopyPropagation.new.run(function)
    assert_equal OP::COPY, function.instructions[function.instructions[0][2]][0]

    function.replace_instructions([
      E::Instruction.new([OP::BR_IF, 0, 2]),
      E::Instruction.new([OP::I32_EQZ, temporary, 1]),
      E::Instruction.new([OP::BR_IF, temporary, 3]),
      E::Instruction.new([OP::RETURN, 1])
    ])
    E::Passes::BranchFusion.new.run(function)
    assert_equal 4, function.instructions.size
    assert_equal OP::BR_IF, function.instructions[2][0]

    constant = function.allocate_constant(13)
    function.replace_instructions([
      E::Instruction.new([OP::BR_IF, 0, 2]),
      E::Instruction.new([OP::I32_SHR_U_IMM, temporary, 1, constant]),
      E::Instruction.new([OP::I32_XOR, 1, 1, temporary]),
      E::Instruction.new([OP::RETURN, 1])
    ])
    E::Passes::Superinstructions.new.run(function)
    assert_equal 4, function.instructions.size
  end

  test "peepholes retain observable intermediate results" do
    instance = load_efflorescence(<<~WAT)
      (module (func (export "run") (param i32) (result i32)
        (local i32)
        local.get 0 i32.const 13 i32.shr_u local.tee 1
        local.get 0 i32.xor
        local.get 1 i32.add))
    WAT
    [0, 123, 0xffffffff].each do |x|
      shifted = x >> 13
      assert_equal ((shifted ^ x) + shifted) & 0xffffffff, instance.run(x).value
    end
    assert instance.runtime.optimized_ir.functions[0].instructions.none? { |i| i[0] == OP::I32_XOR_SHR_U_IMM }
  end

  test "frame reuse resets locals and isolates recursion and public invocations" do
    instance = load_efflorescence(<<~WAT, mir_profile: true)
      (module
        (func $helper (param i32) (result i32) (local i32)
          block
            local.get 0 i32.eqz br_if 0
            i32.const 99 local.set 1
          end
          local.get 1)
        (func (export "run") (result i32)
          i32.const 1 call $helper drop
          i32.const 0 call $helper))
    WAT
    3.times do
      assert_equal 0, instance.run.value
      assert_equal 2, instance.runtime.metrics.frames_created
      assert_equal 3, instance.runtime.metrics.function_entries
    end
    # Invocation-local pools are also independent when the same VM is shared.
    vm = load_efflorescence(File.read(MIX_WAT)).runtime
    results = 8.times.map do |seed|
      Thread.new { 5.times.map { vm.call_unboxed("call_mix", [30, seed]) } }
    end
    results.each_with_index { |thread, seed| assert_equal [reference_mix(30, seed)] * 5, thread.value }
  end

  test "immediates retain unsigned wrapping masked shifts and operand order" do
    %w[add sub mul xor shl shr_u].each do |operation|
      [0, 1, 31, 32, 33, -1, -2147483648].each do |constant|
        wat = <<~WAT
          (module
            (func (export "right") (param i32) (result i32)
              local.get 0 i32.const #{constant} i32.#{operation})
            (func (export "left") (param i32) (result i32)
              i32.const #{constant} local.get 0 i32.#{operation}))
        WAT
        bytes = compile_efflorescence_wat(wat)
        old = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false).runtime
        configurations.each do |disabled|
          vm = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false,
            engine: :efflorescence, disabled_optimizations: disabled).runtime
          %w[left right].each do |export|
            [0, 0xffffffff, 0x80000000, 0x10001].each do |value|
              assert_equal old.call(export, [value]).value, vm.call_unboxed(export, [value]),
                "#{disabled.inspect} #{operation}/#{export}(#{constant}, #{value})"
            end
          end
        end
      end
    end
  end

  test "CLI flags select inspection profiling and unoptimized MIR" do
    assert_raise(Wardite::ArgumentError) { E::Configuration.new([:unknown]) }
    assert_raise(RuntimeError) { Wardite::Cli::Cli.new(["--mir-disable", "copy", "test.wasm"]) }
    cli = Wardite::Cli::Cli.new(["--new-engine", "--mir-disable", "copy", "--mir-disable", "frames",
      "--mir-dump", "--mir-profile", "test.wasm"])
    assert_equal [:copy, :frames], cli.disabled_optimizations
    assert cli.mir_dump
    assert cli.mir_profile
  end

  test "concrete MIR lookups report missing functions and call sites" do
    vm = load_efflorescence(File.read(MIX_WAT)).runtime
    assert_raise(Wardite::EvalError) { vm.ir.function_at(vm.ir.functions.size) }
    function = vm.ir.function_at(0)
    assert_raise(Wardite::EvalError) { function.call_site(function.calls.size) }
  end
end
