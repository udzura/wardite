# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"
require_relative "support/mir_generation_digest"
require "wardite/cli/cli"

class EfflorescenceOptimizerTest < Test::Unit::TestCase
  include EfflorescenceHelper
  E = Wardite::Efflorescence
  OP = E::Opcode

  def configurations
    [[], [:all], *E::Configuration::FEATURES.map { |feature| [feature] }]
  end

  test "large mixed loops coalesce single-use producer copies with the copy pass" do
    fn = E::Function.new(0, [:i32], [], 1)
    fn.uses_store = true
    tmp = fn.allocate_register(0)
    padding = Array.new(E::OptimizationScope::MAX_LOOP_FUNCTION) { E::Instruction.new([OP::I32_ADD, 1, 1, 0]) }
    fn.replace_instructions(padding + [[OP::I32_ADD, tmp, 1, 0], [OP::COPY, 1, tmp],
      [OP::BR_IF, 0, 0], [OP::RETURN, -1]].map { |words| E::Instruction.new(words) })
    E::Optimizer.new(E::Configuration.new([:copy])).optimize_function(fn)
    assert_equal OP::COPY, fn.instructions[-3][0]
    E::Optimizer.new(E::Configuration.new([])).optimize_function(fn)
    assert_equal [OP::I32_ADD, 1, 1, 0], fn.instructions[-3].operands
    assert_equal padding.size + 3, fn.instructions.size
  end

  test "function copy uses actual constant membership and rebuilds parameter and local slots" do
    source = E::Function.new(4, [:i64], [:f64], 1, local_types: [:f32], pool_index: 2)
    source.initial_registers[0] = -7
    source.initial_registers[1] = 0xff800123
    temporary = source.allocate_register(-42, type: :i64)
    bits = source.allocate_constant(-4503599627370205, type: :f64)
    source.allocate_constant(0xff800123, type: :f32)
    130.times { |n| source.allocate_constant(n) }
    source.replace_instructions([E::Instruction.new([OP::RETURN, bits])])
    source.constant_registers.reverse!
    source.constant_registers.concat([bits, -1, source.register_count + 2, 0, 1])

    legacy_constants = (2...source.register_count).select { |register| source.constant_registers.include?(register) }
    constants_visited = 0
    source.constant_registers.define_singleton_method(:each) do |&visit|
      super() do |register|
        constants_visited += 1
        visit.call(register)
      end
    end
    registers_rebuilt = 0
    probes = 0
    trace = TracePoint.new(:call, :c_call) do |event|
      probes += 1 if event.method_id == :include? && event.self.equal?(source.constant_registers)
      registers_rebuilt += 1 if event.defined_class == E::Function && event.method_id == :allocate_register
    end
    copy = trace.enable { source.copy }
    assert_equal source.constant_registers.size, constants_visited
    assert_equal source.register_count - source.parameter_count - source.local_count, registers_rebuilt
    assert_equal 0, probes
    assert_equal [4, 2, 1], [copy.index, copy.pool_index, copy.local_count]
    assert_equal legacy_constants, copy.constant_registers
    assert_equal [0, 0, *source.initial_registers.drop(2)], copy.initial_registers
    assert_equal source.register_types, copy.register_types
    assert_equal [:i64], copy.parameter_types
    assert_equal [:f64], copy.result_types
    assert_true copy.uses_i64
    assert_true copy.uses_float
    copy.instructions.first[1] = temporary
    assert_equal bits, source.instructions.first[1]

    source.constant_registers.clear
    assert_empty source.copy.constant_registers
  end

  test "optimized instructions registers and side tables are independent after lowering" do
    source = E::Function.new(0, [:i32], [:i32], 0)
    result = source.allocate_constant(42)
    source.replace_instructions([E::Instruction.new([OP::RETURN, result])])
    source.handlers << E::HandlerDescriptor.new([E::CatchTarget.new(0, [0], -1, 0, 0)])
    source.throw_sites << E::ThrowSite.new(0, [result])
    source.memory_sites << E::MemorySite.new([0, result, 0])
    source.dynamic_sites << E::DynamicCallSite.new(0, [result], [:i32], [:i32])
    source.uses_eh = true
    source.uses_store = true
    source.uses_dynamic_calls = true
    semantic = E::IR.new([source])
    fingerprint = MIRGenerationDigest.ir(semantic)

    output = E::Optimizer.new(E::Configuration.new([])).optimize(semantic)
    E::Lowerer.new.compile(output)
    assert_equal fingerprint, MIRGenerationDigest.ir(semantic)
    optimized = output.functions.fetch(0)
    optimized.instructions.first[1] = 0
    optimized.initial_registers[result] = 7
    optimized.register_types[result] = :i64
    optimized.constant_registers.clear
    optimized.handlers.first.clauses.first.payload_registers[0] = result
    optimized.throw_sites.first.payload_registers.clear
    optimized.memory_sites.first.sources[0] = result
    optimized.dynamic_sites.first.arguments.clear
    optimized.dynamic_sites.first.parameter_types.clear
    output.entries.first.parameter_types.clear
    assert_equal fingerprint, MIRGenerationDigest.ir(semantic)
  end

  test "a cold load copies the full IR only on the first inspection" do
    bytes = compile_efflorescence_wat('(module (func (export "answer") (result i32) i32.const 42))')
    copies = 0
    trace = TracePoint.new(:call) do |event|
      if event.defined_class == E::IR && event.method_id == :copy && !event.self.functions.empty?
        copies += 1
      end
    end
    trace.enable do
      vm = Wardite.new(buffer: StringIO.new(bytes), enable_wasi: false).runtime
      assert_equal 42, vm.call_unboxed(:answer, [])
      assert_equal 0, copies
      vm.optimized_ir
      vm.semantic_ir
      vm.dump_mir
      assert_equal 1, copies
    end
  end

  test "first MIR inspection uses load-time declarations and leaves execution intact" do
    bytes = compile_efflorescence_wat(<<~WAT)
      (module (memory 1) (global (mut i32) (i32.const 3))
        (func (export "value") (result i32) global.get 0 memory.size i32.add))
    WAT
    [false, true].each do |profile|
      instance = Wardite.new(buffer: StringIO.new(bytes), enable_wasi: false, mir_profile: profile)
      vm = instance.runtime
      reference = Wardite.new(buffer: StringIO.new(bytes), enable_wasi: false, mir_profile: profile).runtime
      assert_equal 4, vm.call_unboxed(:value, [])
      vm.ir.entries.first.result_types.clear
      instance.store.funcs.first.body.clear
      instance.store.funcs.clear
      instance.store.globals.clear
      instance.store.memories.clear
      assert_equal reference.dump_mir, vm.dump_mir
      assert_equal MIRGenerationDigest.ir(reference.optimized_ir), MIRGenerationDigest.ir(vm.optimized_ir)
      assert_same vm.semantic_ir, vm.semantic_ir
      assert_not_same vm.ir.functions.first, vm.semantic_ir.functions.first
    end
  end

  test "dispatch labels are integer literals synchronized with opcode definitions" do
    source = File.read(File.expand_path("../lib/wardite/efflorescence/vm.rb", __dir__))
    methods = source.split(/^      def execute_flat\(frame, pools, active_frames, metrics\)$/).drop(1)
    assert_equal 1, methods.size
    methods.each do |body|
      labels = body.scan(/^          when (\d+) # Opcode::([A-Z_0-9]+)$/)
      expected = OP::NAMES[0..OP::I64_GLOBAL_SET] + OP::NAMES[OP::F32_GLOBAL_GET..]
      assert_equal expected.sort, labels.map(&:last).sort
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

  test "fused i64 equality preserves both edges and signed bit patterns" do
    wasm = compile_efflorescence_wat(<<~WAT)
      (module
        (func (export "eq") (param i64 i64) (result i32)
          block local.get 0 local.get 1 i64.eq br_if 0 i32.const 0 return end i32.const 1))
    WAT
    Dir.mktmpdir do |dir|
      [{disabled_optimizations: [:branch]}, {mir_profile: true}, {mir_cache: dir}, {mir_cache: dir}].each do |options|
        vm = Wardite.new(buffer: StringIO.new(wasm), enable_wasi: false, **options).runtime
        assert_equal 1, vm.call_unboxed(:eq, [-1, -1])
        assert_equal 0, vm.call_unboxed(:eq, [-1, 0xffffffff])
        ops = vm.ir.function_at(0).bytecode.each_slice(E::Lowerer::WIDTH).map(&:first)
        assert_equal !options.key?(:disabled_optimizations), ops.include?(OP::BR_IF_I64_EQ)
      end
    end
  end

  test "masked i64 extraction ignores sign extension and wraps the shift count" do
    [0, 32, 58, 63, 64, 127].each do |shift|
      wat = "(module (func (export \"run\") (param i64) (result i32)
        local.get 0 i64.const #{shift} i64.shr_u i32.wrap_i64 i32.const -1 i32.and))"
      vm = load_efflorescence(wat).runtime
      [-1, -(1 << 63), 0x12345678abcdef01].each do |value|
        expected = ((value % (1 << 64)) >> (shift & 63)) & 0xffffffff
        assert_equal expected, vm.call_unboxed(:run, [value])
      end
      assert_include vm.ir.function_at(0).bytecode.each_slice(E::Lowerer::WIDTH).map(&:first), OP::I32_EXTRACT_I64
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

  %i[MEMORY_INIT MEMORY_COPY MEMORY_FILL CALL_HOST].each do |name|
    test "copy remains live across a side-table read by #{name}" do
      opcode = OP.const_get(name)
      function = E::Function.new(0, [:i32, :i32], [:i32], 1)
      local = 2
      if opcode == OP::CALL_HOST
        function.dynamic_sites << E::DynamicCallSite.new(0, [local], [:i32], [])
        reader = [opcode, -1, 0]
      else
        function.memory_sites << E::MemorySite.new([0, local, 1], data_index: 0)
        reader = [opcode, 0]
      end
      program = [[OP::COPY, local, 0], reader, [OP::COPY, local, 1], [OP::RETURN, local]]
      function.replace_instructions(program.map { |operands| E::Instruction.new(operands) })
      E::Passes::CopyPropagation.new.run(function)
      assert_equal [OP::COPY, local, 0], function.instructions.first.operands
      assert_equal reader, function.instructions.fetch(1).operands
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
      assert_equal ((shifted ^ x) + shifted) & 0xffffffff, instance.runtime.call("run", [x]).value
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
      assert_equal 0, instance.runtime.call("run", []).value
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
        configurations.each do |disabled|
          vm = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false,
            engine: :efflorescence, disabled_optimizations: disabled).runtime
          %w[left right].each do |export|
            [0, 0xffffffff, 0x80000000, 0x10001].each do |value|
              a, b = export == "left" ? [constant, value] : [value, constant]
              a &= 0xffffffff
              expected = case operation
              when "add" then a + b
              when "sub" then a - b
              when "mul" then a * b
              when "xor" then a ^ b
              when "shl" then a << (b & 31)
              when "shr_u" then a >> (b & 31)
              end
              assert_equal expected & 0xffffffff, vm.call_unboxed(export, [value]),
                "#{disabled.inspect} #{operation}/#{export}(#{constant}, #{value})"
            end
          end
        end
      end
    end
  end

  test "CLI flags select inspection profiling and unoptimized MIR" do
    assert_raise(Wardite::ArgumentError) { E::Configuration.new([:unknown]) }
    assert_raise(OptionParser::InvalidOption) { Wardite::Cli::Cli.new(["--stack-engine", "--mir-disable", "copy", "test.wasm"]) }
    cli = Wardite::Cli::Cli.new(["--mir-disable", "copy", "--mir-disable", "frames",
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
