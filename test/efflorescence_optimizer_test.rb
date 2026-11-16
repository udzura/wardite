# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"
require_relative "support/legacy_copy_propagation"
require_relative "support/mir_generation_digest"
require "wardite/cli/cli"

class EfflorescenceOptimizerTest < Test::Unit::TestCase
  include EfflorescenceHelper
  E = Wardite::Efflorescence
  OP = E::Opcode

  def configurations
    [[], [:all], *E::Configuration::FEATURES.map { |feature| [feature] }]
  end

  def propagated_copies(function)
    before = function.copy
    after = function.copy
    LegacyCopyPropagation.propagate(before)
    E::Passes::CopyPropagation.new.send(:propagate, after)
    assert_equal before.instructions.map(&:operands), after.instructions.map(&:operands)
    [before, after]
  end

  test "copy propagation resolves all reads before invalidating the destination" do
    function = E::Function.new(0, [:i32, :i32], [:i32], 2)
    3.times { function.allocate_register(0) }
    constant = function.allocate_constant(17)
    code = [
      [[OP::COPY, 2, 0], [OP::COPY, 2, 0]],
      [[OP::COPY, 3, 2], [OP::COPY, 3, 0]],
      [[OP::COPY, 2, 1], [OP::COPY, 2, 1]], # Rebinding an alias leaves other aliases of its old root intact.
      [[OP::COPY, 4, 3], [OP::COPY, 4, 0]],
      [[OP::I32_ADD, 0, 3, 4], [OP::I32_ADD, 0, 0, 0]],
      [[OP::COPY, 5, 3], [OP::COPY, 5, 3]], # r3 and r4 still hold the old r0.
      [[OP::COPY, 6, 4], [OP::COPY, 6, 4]],
      [[OP::I32_ADD, 3, 5, 5], [OP::I32_ADD, 3, 3, 3]],
      [[OP::CALL, -1, 2, 2, 5, 6, constant, 4, 2], [OP::CALL, -1, 2, 1, 5, 4, constant, 4, 1]],
      [[OP::CALL, 4, 1, 6, 4, 5, constant, 2], [OP::CALL, 4, 1, 4, 4, 5, constant, 1]],
      [[OP::COPY, 0, 6], [OP::COPY, 0, 6]],
      [[OP::COPY, 6, 0], [OP::COPY, 6, 6]], # Source resolves to destination before this write.
      [[OP::COPY, 1, 1], [OP::COPY, 1, 1]],
      [[OP::COPY, 2, constant], [OP::COPY, 2, constant]],
      [[OP::MEMORY_SIZE, 2, 0], [OP::MEMORY_SIZE, 2, 0]], # Write with no register reads.
      [[OP::I32_ADD_IMM, 2, 2, 6], [OP::I32_ADD_IMM, 2, 2, 6]],
      [[OP::RETURN, 2], [OP::RETURN, 2]]
    ]
    function.replace_instructions(code.map { |original, _| E::Instruction.new(original) })
    pass = E::Passes::CopyPropagation.new
    2.times do
      _, rewritten = propagated_copies(function)
      assert_equal code.map(&:last), rewritten.instructions.map(&:operands)
      independent = function.copy
      pass.send(:propagate, independent)
      assert_equal code.map(&:last), independent.instructions.map(&:operands)
    end
    assert_equal code.map(&:first), function.instructions.map(&:operands)
  end

  test "aliases expire at every leader through joins backedges and unreachable blocks" do
    function = E::Function.new(0, [:i32, :i32], [:i32], 2)
    code = [
      [OP::COPY, 2, 0],
      [OP::BR_IF, 2, 4],                         # Split with an alias live.
      [OP::COPY, 2, 1],
      [OP::BR, 5],
      [OP::COPY, 3, 2],                          # Taken edge must read r2.
      [OP::I32_EQZ, 3, 0],                       # Join.
      [OP::BR_IF, 3, 10],
      [OP::COPY, 2, 0],
      [OP::I32_SUB_IMM, 0, 0, 1],
      [OP::BR, 5],
      [OP::RETURN, 2],
      [OP::COPY, 2, 1],                          # Unreachable block.
      [OP::BR_IF, 2, 14],
      [OP::RETURN, 2],
      [OP::RETURN, 2]
    ]
    function.replace_instructions(code.map { |operands| E::Instruction.new(operands.dup) })
    _, rewritten = propagated_copies(function)
    expected = code.map(&:dup)
    expected[1][1] = 0
    expected[12][1] = 1
    assert_equal expected, rewritten.instructions.map(&:operands)
    E::RegisterValidation.new.validate(rewritten)
  end

  test "generation aliases match eager invalidation at every register across one million transitions" do
    rng = Random.new(20261115)
    10_000.times do |sequence|
      count = rng.rand(1..32)
      eager = Array.new(count) { |register| register }
      tagged = E::Passes::CopyAliases.new(count)
      100.times do |step|
        destination = rng.rand(count)
        case rng.rand(4)
        when 0
          source = rng.rand(count)
          resolved = eager.fetch(source)
          actual = tagged.resolve(source)
          LegacyCopyPropagation.invalidate(eager, destination)
          eager[destination] = resolved if destination != resolved
          tagged.write(destination)
          tagged.bind(destination, actual)
        when 1
          LegacyCopyPropagation.invalidate(eager, destination)
          tagged.write(destination)
        when 2
          eager.replace(Array.new(count) { |register| register })
          tagged.next_block
        end
        actual = Array.new(count) { |register| tagged.resolve(register) }
        flunk "sequence #{sequence}, step #{step}: expected #{eager}, got #{actual}" unless eager == actual
      end
    end
  end

  def random_mir_arm(rng, writable_count, register_count)
    Array.new(rng.rand(1..10)) do
      destination = rng.rand(writable_count)
      source = rng.rand(register_count)
      case rng.rand(4)
      when 0 then [OP::COPY, destination, source]
      when 1 then [OP::I32_ADD, destination, source, rng.rand(register_count)]
      when 2 then [OP::I32_ADD_IMM, destination, source, rng.rand(-99..99)]
      when 3 then [OP::I32_EQZ, destination, source]
      end
    end
  end

  test "generated MIR validates and executes identically before and after propagation" do
    rng = Random.new(20261115)
    template = load_efflorescence('(module (func (export "run") (param i32 i32) (result i32) local.get 0))')
    1_000.times do
      function = E::Function.new(0, [:i32, :i32], [:i32], 2)
      (4...rng.rand(5..32)).each { function.allocate_register(0) }
      constant = function.allocate_constant(rng.rand(100))
      code = (4...constant).map { |register| [OP::COPY, register, rng.rand(4)] }
      # All temporaries are defined before the first diamond regardless of input.
      rng.rand(1..4).times do
        choose = [OP::BR_IF, rng.rand(function.register_count), 0]
        join = [OP::BR, 0]
        code << choose
        code.concat(random_mir_arm(rng, constant, function.register_count))
        code << join
        choose[2] = code.size
        code.concat(random_mir_arm(rng, constant, function.register_count))
        join[1] = code.size
      end
      code << [OP::RETURN, rng.rand(function.register_count)]
      function.replace_instructions(code.map { |operands| E::Instruction.new(operands) })
      before, after = propagated_copies(function)
      vms = [function, before, after].map do |variant|
        E::RegisterValidation.new.validate(variant)
        E::Lowerer.new.compile(E::IR.new([variant]))
        E::VM.new(template, cached_functions: [variant], cache_checked: true)
      end
      [[0, 0], [1, 77], [0xffffffff, 0x80000000]].each do |args|
        original, legacy, current = vms.map { |vm| vm.call_unboxed("run", args) }
        assert_equal [original, original], [legacy, current]
      end
    end
  end

  test "hand-built negative source operands retain the old array lookup behavior" do
    function = E::Function.new(0, [:i32], [:i32], 2)
    function.replace_instructions([
      E::Instruction.new([OP::COPY, 1, -3]),
      E::Instruction.new([OP::COPY, 2, -2]),
      E::Instruction.new([OP::RETURN, 2])
    ])
    _, rewritten = propagated_copies(function)
    assert_equal [[OP::COPY, 1, 0], [OP::COPY, 2, 0], [OP::RETURN, 0]], rewritten.instructions.map(&:operands)
  end

  test "propagation preserves invalid targets and register diagnostics" do
    invalid = [
      [[OP::BR, -1]],
      [[OP::COPY, 1, 10], [OP::RETURN, 1]],
      [[OP::COPY, 0, 1], [OP::RETURN, 0]]
    ]
    invalid.each do |code|
      function = E::Function.new(0, [:i32], [:i32], 0)
      function.allocate_register(0)
      function.replace_instructions(code.map { |operands| E::Instruction.new(operands) })
      errors = [
        LegacyCopyPropagation.method(:propagate),
        E::Passes::CopyPropagation.new.method(:propagate)
      ].map do |propagate|
        input = function.copy
        begin
          propagate.call(input)
          E::RegisterValidation.new.validate(input)
          flunk "accepted invalid MIR: #{code.inspect}"
        rescue E::TranslationError, IndexError, NoMethodError => error
          [error.class, error.message.lines.first]
        end
      end
      assert_equal errors.first, errors.last
    end
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

  test "dispatch labels are integer literals synchronized with opcode definitions" do
    source = File.read(File.expand_path("../lib/wardite/efflorescence/vm.rb", __dir__))
    methods = source.split(/^      def execute_flat\(frame, pools, active_frames, metrics\)$/).drop(1)
    assert_equal 1, methods.size
    methods.each do |body|
      labels = body.scan(/^          when (\d+) # Opcode::([A-Z_0-9]+)$/)
      expected = OP::NAMES[0..OP::I64_GLOBAL_SET] + OP::NAMES[OP::F32_GLOBAL_GET..OP::F64_GLOBAL_SET]
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
