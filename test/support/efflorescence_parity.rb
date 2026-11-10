# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"

module EfflorescenceParity
  ROOT = File.expand_path("../..", __dir__)
  WORKER = File.join(ROOT, "test/spinel/efflorescence_parity.rb")

  Observation = Data.define(:result, :memory, :globals, :host, :dispatch) do
    def initialize(result:, memory: "-", globals: "", host: "", dispatch: [])
      super
    end
  end

  Fixture = Data.define(:id, :wat, :steps, :windows, :stdout, :legacy) do
    def initialize(id:, wat:, steps:, windows: "-", stdout: "", legacy: true)
      super
    end
  end

  def self.capture(*command)
    output, errors, status = Open3.capture3(*command)
    raise "#{command.inspect}\n#{output}#{errors}" unless status.success?
    [output, errors]
  end

  def self.compile(directory, fixtures)
    fixtures.to_h do |fixture|
      source = File.join(directory, "#{fixture.id.tr('/.', '__')}.wat")
      binary = source.sub(/\.wat\z/, ".wasm")
      File.write(source, fixture.wat)
      capture("wasm-tools", "parse", source, "-o", binary)
      [fixture.id, binary]
    end
  end

  def self.worker(directory, runtime)
    return [RbConfig.ruby, "-I#{ROOT}/lib", WORKER] if runtime == :cruby
    raise "unknown runtime #{runtime}" unless runtime == :spinel

    binary = File.join(directory, "native-worker")
    capture(ENV.fetch("SPINEL", "spinel"), "--strict-require", "-O2", "-I#{ROOT}/lib", WORKER, "-o", binary)
    [binary]
  end

  def self.observe(command, directory, engine, fixtures, binaries, disabled)
    plan = File.join(directory, "plan.tsv")
    result = File.join(directory, "result.tsv")
    File.write(plan, fixtures.map do |fixture|
      [fixture.id, binaries.fetch(fixture.id), fixture.steps.map(&:first).join(","), fixture.windows].join("\t")
    end.join("\n") + "\n")
    stdout, stderr = capture(*command, engine.to_s, plan, result, disabled.join(","))
    expected_stdout = fixtures.map(&:stdout).join
    raise "#{engine} stdout: #{expected_stdout.inspect} expected, #{stdout.inspect} observed" unless stdout == expected_stdout
    rows = File.readlines(result, chomp: true).map do |line|
      id, export, result, memory, globals, host, dispatch = line.split("\t", -1)
      [id, export, Observation.new(result: result, memory: memory, globals: globals, host: host, dispatch: dispatch.split(","))]
    end
    ids = fixtures.flat_map { |fixture| fixture.steps.map { |export, _| [fixture.id, export] } }
    raise "#{engine} did not complete the plan\n#{stderr}" unless rows.map { |id, export, _| [id, export] } == ids
    rows
  end

  def self.result_matches?(expected, actual)
    return expected == actual unless expected.end_with?(":qnan")
    type, value = actual.split(":", 2)
    return false unless expected.start_with?("#{type}:") && value

    mask = type == "f32" ? 0x7fc00000 : 0x7ff8000000000000
    (Integer(value) & mask) == mask
  end

  def self.check_rows(engine, fixtures, rows)
    index = 0
    fixtures.each do |fixture|
      fixture.steps.each do |export, expected|
        _, _, actual = rows.fetch(index)
        index += 1
        label = "#{engine} #{fixture.id} #{export}"
        unless result_matches?(expected.result, actual.result) && expected.memory == actual.memory &&
            expected.globals == actual.globals && expected.host == actual.host
          raise "#{label}\nexpected #{expected.inspect}\nobserved #{actual.inspect}"
        end
        if engine == :efflorescence
          missing = expected.dispatch - actual.dispatch
          raise "#{label} did not dispatch #{missing.join(', ')}" unless missing.empty?
        end
      end
    end
  end

  def self.run(fixtures, runtime:, configurations: [[:all]])
    raise "duplicate fixture ID" unless fixtures.map(&:id).uniq.size == fixtures.size

    Dir.mktmpdir("wardite-parity") do |directory|
      command = worker(directory, runtime)
      binaries = compile(directory, fixtures)
      configurations.each do |disabled|
        rows = observe(command, directory, :efflorescence, fixtures, binaries, disabled)
        check_rows(:efflorescence, fixtures, rows)
      end
      legacy = fixtures.select { |fixture| fixture.legacy == true }
      unless legacy.empty?
        rows = observe(command, directory, :stack, legacy, binaries, [])
        check_rows(:stack, legacy, rows)
      end
    end
  end

  def self.state_fixture
    wat = <<~WAT
      (module
        (import "env" "capture_i32" (func $record (param i32)))
        (import "env" "write_i32" (func $emit (param i32)))
        (memory 1 2)
        (data (i32.const 1) "abc")
        (global $count (mut i32) (i32.const 9))
        (func $start i32.const 1 call $record)
        (start $start)
        (func (export "mutate") (result i32)
          i32.const 0 i32.const 42 i32.store8
          global.get $count i32.const 1 i32.add global.set $count
          i32.const 2 call $emit
          global.get $count)
        (func (export "fail")
          i32.const 4 i32.const 17 i32.store8
          i32.const 3 call $record
          unreachable
          i32.const 4 call $record)
      )
    WAT
    first = Observation.new(result: "i32:10", memory: "1:65536:2a61626300000000", globals: "i32:10",
      host: "1,2", dispatch: %w[I32_STORE8 GLOBAL_GET GLOBAL_SET CALL_HOST])
    failure = Observation.new(result: "trap:unreachable", memory: "1:65536:2a61626311000000", globals: "i32:10",
      host: "1,2,3", dispatch: %w[I32_STORE8 CALL_HOST TRAP])
    Fixture.new(id: "state_order", wat: wat, windows: "0:8", stdout: "guest:2\n",
      steps: [["mutate", first], ["fail", failure]])
  end
end
