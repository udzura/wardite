# frozen_string_literal: true

require_relative "efflorescence_opcode_cases"

module EfflorescenceManifestRun
  extend self

  def verify_coverage(fixtures)
    by_id = fixtures.to_h { |fixture| [fixture.id, fixture] }
    EfflorescenceManifest.rows.each do |row|
      row.values_at("normal", "boundary", "trap").each do |id|
        next if ["-", "n/a"].include?(id)
        fixture = by_id.fetch(id)
        expected = fixture.steps.fetch(0).fetch(1)
        raise "#{id} has no expectation" if expected.result.empty? || expected.dispatch.empty?
      end
    end
  end

  def verify_source_routes(fixtures, binaries)
    cases = fixtures.select do |fixture|
      op = fixture.id.split("/").first
      %w[source frame].include?(EfflorescenceOpcodeCases::ROUTES.fetch(op)["mir"])
    end
    cases.each do |fixture|
      op = fixture.id.split("/").first
      decoder = EfflorescenceOpcodeCases::ROUTES.fetch(op)["decoder"].to_sym
      instance = Wardite.new(path: binaries.fetch(fixture.id), engine: :efflorescence, enable_wasi: false)
      instructions = instance.code_section.func_codes.flat_map(&:body)
      raise "#{fixture.id}: missing decoded #{decoder}" unless instructions.any? { |instruction| instruction[1] == decoder }
    end
  end

  def reference_result(fixture, path)
    expected = fixture.steps.fetch(0).fetch(1).result
    kind = expected.split(":").first
    export = %w[f32 f64].include?(kind) ? "__bits" : "run"
    output, errors, status = Open3.capture3("wasmtime", "run", "-W", "exceptions=y", "--invoke", export, path)
    if status.success?
      return "void" if expected == "void" && output.empty?
      bits = Integer(output)
      bits &= 0xffffffff if %w[i32 f32].include?(kind)
      "#{kind}:#{bits}"
    elsif expected.start_with?("exception:") && errors.include?("thrown Wasm exception")
      "exception"
    else
      reason = {
        "unreachable" => /unreachable/,
        "zero" => /integer divide by zero/,
        "invalid" => /invalid conversion to integer/,
        "overflow" => /integer overflow/,
        "bounds" => /out of bounds memory access/,
        "indirect" => /uninitialized element|undefined element|indirect call type mismatch/
      }.find { |_, pattern| errors.match?(pattern) }
      raise "#{fixture.id}: Wasmtime failed\n#{errors}" unless reason
      "trap:#{reason.first}"
    end
  end

  def compare_reference(fixtures, binaries)
    fixtures.each do |fixture|
      path = binaries.fetch(fixture.id)
      EfflorescenceParity.capture("wasm-tools", "validate", path)
      expected = fixture.steps.fetch(0).fetch(1).result
      expected = "exception" if expected.start_with?("exception:")
      actual = reference_result(fixture, path)
      unless EfflorescenceParity.result_matches?(expected, actual)
        raise "#{fixture.id}: expected #{expected}, Wasmtime returned #{actual}"
      end
    end
  end

  def compare_stack(command, directory, runtime, fixtures, binaries)
    path = File.join(__dir__, "efflorescence_legacy_differences.tsv")
    differences = CSV.read(path, headers: true, col_sep: "\t")
      .select { |row| ["both", runtime.to_s].include?(row["runtime"]) }
    overrides = differences.to_h { |row| [row["fixture"], row] }
    raise "duplicate legacy difference" unless overrides.size == differences.size
    legacy = fixtures.select(&:legacy).map do |fixture|
      difference = overrides.delete(fixture.id)
      next fixture unless difference
      raise "unclassified difference for #{fixture.id}" if difference["reason"].to_s.empty?
      export, observation = fixture.steps.fetch(0)
      changed = observation.with(result: difference["result"], memory: difference["memory"])
      raise "redundant legacy difference for #{fixture.id}" if changed == observation
      fixture.with(steps: [[export, changed]])
    end
    raise "unknown legacy difference: #{overrides.keys.join(', ')}" unless overrides.empty?
    rows = EfflorescenceParity.observe(command, directory, :stack, legacy, binaries, [])
    EfflorescenceParity.check_rows(:stack, legacy, rows)
    puts "#{runtime}: #{legacy.size} stack comparisons, #{differences.size} classified differences"
  end

  def run(runtimes, reference: true)
    fixtures = EfflorescenceOpcodeCases.examples
    verify_coverage(fixtures)
    Dir.mktmpdir("wardite-manifest") do |directory|
      binaries = EfflorescenceParity.compile(directory, fixtures)
      verify_source_routes(fixtures, binaries)
      compare_reference(fixtures, binaries) if reference
      runtimes.each do |runtime|
        command = EfflorescenceParity.worker(directory, runtime)
        rows = EfflorescenceParity.observe(command, directory, :efflorescence, fixtures, binaries, [:all])
        EfflorescenceParity.check_rows(:efflorescence, fixtures, rows)
        puts "#{runtime}: #{fixtures.size} fixtures, 188 M0 opcodes + 3 EH"
        compare_stack(command, directory, runtime, fixtures, binaries)
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  puts EfflorescenceParity.capture("wasmtime", "--version").first
  puts EfflorescenceParity.capture("wasm-tools", "--version").first
  EfflorescenceManifestRun.run(%i[cruby spinel])
end
