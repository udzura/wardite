# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"

class EfflorescenceInliningTest < Test::Unit::TestCase
  include EfflorescenceHelper
  E = Wardite::Efflorescence
  OP = E::Opcode

  def instructions(function)
    function.instructions.map { |instruction| instruction.operands.dup }
  end

  test "small leaf calls disappear without changing the semantic MIR or exports" do
    vm = load_efflorescence(File.read(MIX_WAT), mir_profile: true).runtime
    assert_equal 1, vm.semantic_ir.function_at(2).instructions.count { |i| i[0] == OP::CALL }
    assert_equal 0, vm.optimized_ir.function_at(2).instructions.count { |i| i[0] == OP::CALL }
    assert_equal [5, 9, 9], vm.optimized_ir.functions.map { |fn| fn.instructions.size }
    %w[inline_mix call_mix].each do |name|
      assert_equal reference_mix(1000, 0xffffffff), vm.call_unboxed(name, [1000, 0xffffffff])
      assert_equal 7003, vm.metrics.dispatches
      assert_equal 1, vm.metrics.function_entries
      assert_equal 1, vm.metrics.frames_created
    end
    uninlined = load_efflorescence(File.read(MIX_WAT), disabled_optimizations: [:inline]).runtime
    assert_equal [5, 9, 6], uninlined.ir.functions.map { |fn| fn.instructions.size }
    assert_equal vm.semantic_ir.functions.map { |fn| instructions(fn) },
      uninlined.semantic_ir.functions.map { |fn| instructions(fn) }
  end

  test "parameter snapshots local zeroing constant returns and void calls survive every pass toggle" do
    bytes = compile_efflorescence_wat(INLINE_WAT)
    baseline = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false).runtime
    configurations = [[], [:all], *E::Configuration::FEATURES.map { |feature| [feature] }]
    configurations.each do |disabled|
      [false, true].each do |profile|
        vm = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false,
          engine: :efflorescence, disabled_optimizations: disabled, mir_profile: profile).runtime
        [0, 123, 0xffffffff, 0x80000000].each do |seed|
          cases = [["snapshot", [seed], (seed + 1) % (2**32)], ["constant", [], 0xffffffff],
            ["void", [seed], seed], ["branch", [0, seed], 99], ["branch", [1, seed], seed]]
          [0, 1, 10, 1000].each { |n| cases << ["loop", [n, seed], n * seed % (2**32)] }
          2.times do
            cases.each do |name, args, expected|
              assert_equal expected, baseline.call(name, args).value
              assert_equal expected, vm.call_unboxed(name, args), "#{disabled.inspect}, profile=#{profile}, #{name}#{args}"
            end
          end
        end
      end
    end
    # Every helper in this fixture is a small leaf; this exercises expansion,
    # rather than merely comparing a fixture rejected by the size limit.
    vm = load_efflorescence(INLINE_WAT).runtime
    assert vm.ir.functions.all? { |fn| fn.instructions.none? { |i| i[0] == OP::CALL } }
  end

  test "branch targets enter argument and local initialization at the expanded call" do
    callee = E::Function.new(0, [:i32], [:i32], 1)
    callee.replace_instructions([E::Instruction.new([OP::I32_ADD, 1, 0, 1]), E::Instruction.new([OP::RETURN, 1])])
    caller = E::Function.new(1, [:i32], [:i32], 0)
    destination = caller.allocate_register(0)
    caller.replace_instructions([
      E::Instruction.new([OP::BR, 2]), E::Instruction.new([OP::TRAP]),
      E::Instruction.new([OP::CALL, destination, 0, 0]), E::Instruction.new([OP::RETURN, destination])
    ])
    ir = E::IR.new([callee, caller])
    assert_equal [1], E::Passes::Inlining.new.run(ir)
    target = caller.instructions[0][1]
    assert_equal OP::COPY, caller.instructions[target][0]
    assert_equal 0, caller.instructions[target][2]
    assert_equal OP::COPY, caller.instructions[target + 1][0]
    assert_include caller.constant_registers, caller.instructions[target + 1][2]
    E::RegisterValidation.new.validate(caller)
    E::Lowerer.new.compile(ir)
    assert_equal target * 4, caller.bytecode[1]
  end

  test "recursive branching trapping oversized and unknown callees keep their calls" do
    leaf = E::Function.new(0, [:i32], [:i32], 0)
    caller = E::Function.new(1, [:i32], [:i32], 0)
    caller.replace_instructions([E::Instruction.new([OP::CALL, 0, 0, 0]), E::Instruction.new([OP::RETURN, 0])])
    rejected = [
      [[OP::CALL, 0, 0, 0], [OP::RETURN, 0]],
      [[OP::BR, 1], [OP::RETURN, 0]],
      [[OP::BR_IF, 0, 1], [OP::RETURN, 0]],
      [[OP::TRAP], [OP::RETURN, 0]],
      [[OP::PROFILE, OP::RETURN, 1, 0], [OP::RETURN, 0]],
      [[999], [OP::RETURN, 0]],
      [[OP::RETURN, 0], [OP::RETURN, 0]],
      Array.new(E::Passes::Inlining::MAX_INSTRUCTIONS) { [OP::COPY, 0, 0] } + [[OP::RETURN, 0]]
    ]
    rejected.each do |code|
      leaf.replace_instructions(code.map { |operands| E::Instruction.new(operands) })
      assert_empty E::Passes::Inlining.new.run(E::IR.new([leaf, caller]))
      assert_equal OP::CALL, caller.instructions.first[0]
    end
    leaf.replace_instructions([E::Instruction.new([OP::RETURN, 0])])
    E::Passes::Inlining::MAX_REGISTERS.times { leaf.allocate_register(0) }
    assert_empty E::Passes::Inlining.new.run(E::IR.new([leaf, caller]))
  end

  test "one snapshot round and per-caller budgets bound expansion" do
    leaf = E::Function.new(0, [:i32], [:i32], 0)
    leaf.replace_instructions([E::Instruction.new([OP::I32_ADD_IMM, 0, 0, 1]), E::Instruction.new([OP::RETURN, 0])])
    middle = E::Function.new(1, [:i32], [:i32], 0)
    middle.replace_instructions([E::Instruction.new([OP::CALL, 0, 0, 0]), E::Instruction.new([OP::RETURN, 0])])
    caller = E::Function.new(2, [:i32], [:i32], 0)
    caller.replace_instructions([E::Instruction.new([OP::CALL, 0, 1, 0]), E::Instruction.new([OP::RETURN, 0])])
    ir = E::IR.new([leaf, middle, caller])
    assert_equal [1], E::Passes::Inlining.new.run(ir)
    assert_equal OP::CALL, caller.instructions.first[0]
    assert_equal 1, caller.instructions.first[2]

    2.times do |kind|
      body = kind == 0 ? Array.new(6) { E::Instruction.new([OP::I32_ADD_IMM, 0, 0, 1]) } : []
      leaf.replace_instructions(body + [E::Instruction.new([OP::RETURN, 0])])
      caller = E::Function.new(1, [:i32], [:i32], 0)
      caller.replace_instructions(Array.new(300) { E::Instruction.new([OP::CALL, 0, 0, 0]) } + [E::Instruction.new([OP::RETURN, 0])])
      size = caller.instructions.size
      registers = caller.register_count
      E::Passes::Inlining.new.run(E::IR.new([leaf, caller]))
      assert caller.instructions.any? { |i| i[0] == OP::CALL }
      assert_operator caller.instructions.size - size, :<=, E::Passes::Inlining::MAX_ADDED_INSTRUCTIONS
      assert_operator caller.register_count - registers, :<=, E::Passes::Inlining::MAX_ADDED_REGISTERS
      assert_operator caller.register_count, :>, registers
      E::RegisterValidation.new.validate(caller)
    end
  end

  test "only pre-rewrite leaves are copied regardless of pool order and imports" do
    # Module indices 0 and 3 are imports. Defined functions are stored in a
    # different order to exercise both module-index lookup and snapshot timing.
    leaf_index = 1
    code = {
      1 => [[OP::I32_ADD_IMM, 0, 0, 1], [OP::RETURN, 0]],
      2 => [[OP::CALL, 0, leaf_index, 0], [OP::RETURN, 0]],
      4 => [[OP::CALL, 0, 2, 0], [OP::RETURN, 0]],
      5 => [[OP::CALL, 0, leaf_index, 0], [OP::RETURN, 0]]
    }
    [[1, 2, 4, 5], [5, 4, 2, 1]].each do |order|
      functions = order.each_with_index.map do |index, pool|
        E::Function.new(index, [:i32], [:i32], 0, pool_index: pool).tap do |function|
          function.replace_instructions(code.fetch(index).map { |operands| E::Instruction.new(operands) })
        end
      end
      entries = (0..5).map do |index|
        pool = order.index(index)
        pool ? E::FunctionEntry.new(:defined, [:i32], [:i32], pool, -1) :
          E::FunctionEntry.new(:host, [:i32], [:i32], -1, index == 0 ? 0 : 1)
      end
      ir = E::IR.new(functions, entries: entries)
      copied = []
      trace = TracePoint.new(:call) do |event|
        copied << event.self.index if event.defined_class == E::Function && event.method_id == :copy
      end
      changed = trace.enable { E::Passes::Inlining.new.run(ir) }
      assert_equal order & [2, 5], changed
      assert_equal [leaf_index], copied
      assert_equal code.fetch(1), instructions(ir.function_at(1))
      assert_equal code.fetch(4), instructions(ir.function_at(4))
      assert_equal [[OP::COPY, 1, 0], [OP::I32_ADD_IMM, 1, 1, 1],
                    [OP::COPY, 0, 1], [OP::RETURN, 0]], instructions(ir.function_at(2))
      assert_equal instructions(ir.function_at(2)), instructions(ir.function_at(5))
    end
  end

  test "unchanged callers keep their original instruction objects" do
    leaf = E::Function.new(0, [], [], 0)
    leaf.replace_instructions([E::Instruction.new([OP::TRAP])])
    caller = E::Function.new(1, [], [], 0)
    caller.replace_instructions([[OP::BR, 1], [OP::CALL, -1, 0], [OP::RETURN, -1]].map { |operands| E::Instruction.new(operands) })
    ir = E::IR.new([leaf, caller])
    original = ir.functions.map(&:instructions)
    copies = original.map(&:dup)
    rewrites = 0
    trace = TracePoint.new(:call) do |event|
      rewrites += 1 if event.defined_class == E::Rewrite && event.method_id == :initialize
    end
    assert_empty trace.enable { E::Passes::Inlining.new.run(ir) }
    assert_equal 0, rewrites
    ir.functions.each_with_index do |function, index|
      assert_same original.fetch(index), function.instructions
      function.instructions.each_with_index do |instruction, pc|
        assert_same copies.fetch(index).fetch(pc), instruction
      end
    end
  end

  test "skipping rewrites still rejects invalid direct calls with no snapshots" do
    caller = E::Function.new(1, [], [], 0, pool_index: 0)
    entries = [E::FunctionEntry.new(:host, [], [], -1, 0), E::FunctionEntry.new(:defined, [], [], 0, -1)]
    ir = E::IR.new([caller], entries: entries)
    { -1 => "invalid MIR function index -1", 2 => "invalid MIR function index 2", 0 => "MIR function 0 is not defined" }.each do |index, message|
      caller.replace_instructions([E::Instruction.new([OP::CALL, -1, index]), E::Instruction.new([OP::RETURN, -1])])
      error = assert_raise(Wardite::EvalError) { E::Passes::Inlining.new.run(ir) }
      assert_equal message, error.message
    end
  end

  test "an eligible call above the available budget leaves its caller intact" do
    leaf = E::Function.new(0, [], [], 0)
    leaf.replace_instructions([E::Instruction.new([OP::RETURN, -1])])
    caller = E::Function.new(1, [], [], 0)
    call = E::Instruction.new([OP::CALL, -1, 0])
    original = [call, E::Instruction.new([OP::RETURN, -1])]
    caller.replace_instructions(original)
    pass = E::Passes::Inlining.new
    # Real eligible leaves fit an empty budget. Override the estimate to
    # exercise the pre-scan's budget rejection independently of eligibility.
    pass.define_singleton_method(:instruction_growth) { |_, _| E::Passes::Inlining::MAX_ADDED_INSTRUCTIONS + 1 }
    assert_empty pass.run(E::IR.new([leaf, caller]))
    assert_same original, caller.instructions
    assert_same call, caller.instructions.first
  end

  test "the last expansion may use exactly the instruction or register budget" do
    [[7, 1, 64, 8], [0, 32, 8, 256], [7, 32, 64, 256]].each do |body_size, registers, growth, added_registers|
      leaf = E::Function.new(0, [:i32], [:i32], 0)
      (registers - 1).times { leaf.allocate_register(0) }
      body = Array.new(body_size) { E::Instruction.new([OP::I32_ADD_IMM, 0, 0, 1]) }
      leaf.replace_instructions(body + [E::Instruction.new([OP::RETURN, 0])])
      caller = E::Function.new(1, [:i32], [:i32], 0)
      caller.replace_instructions(Array.new(9) { E::Instruction.new([OP::CALL, 0, 0, 0]) } + [E::Instruction.new([OP::RETURN, 0])])
      assert_equal [1], E::Passes::Inlining.new.run(E::IR.new([leaf, caller]))
      assert_equal 1, caller.instructions.count { |instruction| instruction[0] == OP::CALL }
      assert_equal 10 + growth, caller.instructions.size
      assert_equal 1 + added_registers, caller.register_count
      E::RegisterValidation.new.validate(caller)
    end
  end

  test "copy liveness removes overwritten initializers while retaining edge and snapshot uses" do
    fn = E::Function.new(0, [:i32, :i32], [:i32], 0)
    temp = fn.allocate_register(0)
    fn.replace_instructions([
      E::Instruction.new([OP::COPY, temp, 0]),
      E::Instruction.new([OP::I32_ADD_IMM, temp, 1, 1]),
      E::Instruction.new([OP::RETURN, temp])
    ])
    E::Passes::CopyPropagation.new.run(fn)
    assert_equal [OP::I32_ADD_IMM, OP::RETURN], fn.instructions.map { |i| i[0] }
    fn.replace_instructions([
      E::Instruction.new([OP::COPY, temp, 0]), E::Instruction.new([OP::BR_IF, 1, 3]),
      E::Instruction.new([OP::COPY, temp, 1]), E::Instruction.new([OP::RETURN, temp])
    ])
    E::Passes::CopyPropagation.new.run(fn)
    assert_equal OP::COPY, fn.instructions.first[0]
    assert_equal OP::RETURN, fn.instructions[fn.instructions[1][2]][0]
    E::RegisterValidation.new.validate(fn)
  end
end
