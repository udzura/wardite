# frozen_string_literal: true

require_relative "efflorescence_parity"

module EfflorescenceBoundaryCases
  extend self
  Observation = EfflorescenceParity::Observation
  Fixture = EfflorescenceParity::Fixture

  def configurations
    [[], [:all], *Wardite::Efflorescence::Configuration::FEATURES.map { |pass| [pass] }]
  end

  def fixtures
    [EfflorescenceParity.state_fixture, start_fixture, *store_fixtures, recovery_fixture, *failure_fixtures]
  end

  def start_fixture
    wat = <<~WAT
      (module
        (type $sig (func (param i32) (result i32)))
        (import "env" "capture_i32" (func $record (param i32)))
        (memory 1 2)
        (table 3 funcref)
        (elem (i32.const 1) func $next)
        (data (i32.const 0) "\\03")
        (global $state (mut i32) (i32.const 4))
        (func $next (type $sig) local.get 0 i32.const 1 i32.add)
        (func $start
          i32.const 0 i32.load8_u global.get $state i32.add
          i32.const 1 call_indirect (type $sig) global.set $state
          global.get $state call $record)
        (start $start)
        (func (export "run") (result i32) global.get $state))
    WAT
    observed = Observation.new(result: "i32:8", memory: "1:65536:03000000", globals: "i32:8", host: "8",
      dispatch: %w[GLOBAL_GET RETURN])
    Fixture.new(id: "initialized_start", wat: wat, windows: "0:4", steps: [["run", observed]])
  end

  def store_fixtures
    wat = <<~WAT
      (module
        (memory 1 2)
        (data $passive "\\11\\22\\33\\44")
        (global $value (mut i64) (i64.const -7))
        (func (export "grow") (result i32) i32.const 1 memory.grow)
        (func (export "transfer") (result i32)
          i32.const 65534 i32.const 0 i32.const 4 memory.init $passive
          i32.const 65535 i32.const 65534 i32.const 3 memory.copy
          i32.const 65534 i32.load)
        (func $mutate i64.const 99 global.set $value)
        (func (export "snapshot") (result i64) global.get $value call $mutate)
        (func (export "size") (result i32) memory.size))
    WAT
    grow = Observation.new(result: "i32:1", memory: "2:131072:0000000000000000", globals: "i64:-7",
      dispatch: %w[MEMORY_GROW])
    copy = Observation.new(result: "i32:#{0x33221111}", memory: "2:131072:0000111122330000", globals: "i64:-7",
      dispatch: %w[MEMORY_INIT MEMORY_COPY I32_LOAD])
    snapshot = Observation.new(result: "i64:-7", memory: copy.memory, globals: "i64:99",
      dispatch: %w[I64_GLOBAL_GET I64_GLOBAL_SET CALL])
    fresh = Observation.new(result: "i32:1", memory: "1:65536:00000000", globals: "i64:-7",
      dispatch: %w[MEMORY_SIZE])
    [Fixture.new(id: "grow_passive_overlap", wat: wat, windows: "65532:8", legacy: false,
       steps: [["grow", grow], ["transfer", copy], ["snapshot", snapshot]]),
     Fixture.new(id: "fresh_instance", wat: wat, windows: "65532:8", steps: [["size", fresh]])]
  end

  def recovery_fixture
    fixture = EfflorescenceParity.state_fixture
    recovery = Observation.new(result: "i32:17", memory: "1:65536:2a61626311000000", globals: "i32:10",
      host: "1,2,3", dispatch: %w[I32_LOAD8_U RETURN])
    fixture.with(id: "recover_after_trap", legacy: false, steps: fixture.steps + [["recover", recovery]])
  end

  def failure_fixtures
    import = '(import "env" "capture_i32" (func $record (param i32)))'
    start = '(func $start i32.const 7 call $record) (start $start)'
    [
      ["data_before_start", "#{start} (memory 1) (data (i32.const 65535) \"ab\")",
        "load:active data segment out of bounds", "", false],
      ["element_before_start", "#{start} (table 1 funcref) (elem (i32.const 1) func $start)",
        "load:active element segment out of bounds", "", true],
      ["signature_before_start", "(func $start (param i32) i32.const 7 call $record) (start $start)",
        "load:start function must have no parameters or results", "", false],
      ["dead_instruction_before_start", "#{start} (func unreachable i32.const 1 i32.const 2 i32.const 0 select (result i32) drop)",
        "load:Efflorescence: function 2, Wasm PC 4: unsupported instruction select_t", "", false],
      ["dead_type_before_start", "#{start} (func unreachable f64.const 1 i32.eqz drop)",
        "load:Efflorescence: function 2, Wasm PC 2: expected i32, got f64", "", false],
      ["dead_index_before_start", "#{start} (func unreachable call 99)",
        "load:Efflorescence: function 2, Wasm PC 1: invalid call target 99", "", false],
      ["multi_value_before_start", "#{start} (func (result i32 f64) unreachable)",
        "load:Efflorescence: function 2 requires a numeric signature with at most one result (i32/i64/f32/f64)", "", false],
      ["link_before_start", %((import "env" "absent" (func)) #{start}),
        "link:function absent not found", "", [["-", Observation.new(result: "load:success", host: "7")]]],
      ["start_trap_order", "(func $start i32.const 7 call $record unreachable i32.const 8 call $record) (start $start)",
        "trap:unreachable", "7", true]
    ].map do |id, contents, result, host, legacy|
      step = Observation.new(result: result, host: host)
      Fixture.new(id: id, wat: "(module #{import} #{contents})", steps: [["-", step]], legacy: legacy)
    end
  end

  CLI_WAT = <<~WAT
    (module
      (global $state (mut i32) (i32.const 0))
      (func $start i32.const 42 global.set $state)
      (start $start)
      (func $plus (param i32) (result i32) local.get 0 i32.const 1 i32.add)
      (func $float (param i32) (result i32)
        f32.const -0 drop local.get 0 call $plus)
      (func (export "mixed") (result i32) i32.const 41 call $float)
      (func (export "pure") (result i32) i32.const 41 call $plus)
      (func (export "started") (result i32) global.get $state)
      (func (export "f32") (param f32) (result f32) local.get 0))
  WAT

  def check_cli(test, command)
    Dir.mktmpdir("wardite-cli-m6") do |directory|
      source = File.join(directory, "cli.wat")
      binary = File.join(directory, "cli.wasm")
      File.write(source, CLI_WAT)
      EfflorescenceParity.capture("wasm-tools", "parse", source, "-o", binary)
      [[[], "started"], [["--new-engine"], "started"], [["--new-engine", "--mir-profile"], "mixed"],
       [["--new-engine", "--mir-profile"], "pure"], [["--new-engine", "--mir-profile", "--mir-disable", "inline"], "pure"]].each do |options, name|
        stdout, stderr = EfflorescenceParity.capture(*command, *options, "--no-wasi", "--invoke", name, binary)
        test.assert_equal "", stdout
        test.assert_include stderr, "return value: I32(42)"
        next unless options.include?("--mir-profile")
        entries = name == "mixed" ? 3 : options.include?("--mir-disable") ? 2 : 1
        test.assert_include stderr, "function_entries=#{entries} "
      end
      stdout, stderr = EfflorescenceParity.capture(*command, "--new-engine", "--mir-dump", "--mir-profile",
        "--no-wasi", "--invoke", "f32", binary, "1.25")
      test.assert_equal "", stdout
      test.assert_include stderr, "f32 0x80000000"
      test.assert_include stderr, "Optimized MIR"
      test.assert_include stderr, "dispatches="
      test.assert_include stderr, "return value: F32(1.25)"
    end
  end
end
