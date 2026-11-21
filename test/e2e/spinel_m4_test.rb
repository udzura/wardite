# frozen_string_literal: true

require "test_helper"
require_relative "../support/efflorescence_helper"
require_relative "../support/efflorescence_m4_cases"
require_relative "../support/efflorescence_m4_alu_cases"

class WarditeSpinelM4Test < Test::Unit::TestCase
  include EfflorescenceHelper
  include EfflorescenceM4Cases
  include EfflorescenceM4ALUCases

  test "native i64 decode, registers and boxing preserve all bits" do
    run_worker("efflorescence_m4_values", "M4 signed registers passed")
  end

  test "native mixed control and public boundaries" do
    run_worker("efflorescence_m4", "M4 control passed", CONTROL_WAT)
  end

  test "native i64 instructions match the CRuby reference vectors" do
    functions, rows = alu_cases
    run_worker("efflorescence_m4_vectors", "M4 vectors passed", "(module #{functions})", rows) do |worker, arguments|
      next unless ENV["WARDITE_MIR_JIT"] == "1" && RUBY_PLATFORM.match?(/arm64-darwin/)

      # The worker also checks every value and trap against the M4 reference.
      # Tracing proves which exports ran natively and which inputs used replay.
      output, status = Open3.capture2e({"WARDITE_MIR_JIT" => "1", "WARDITE_TRACE" => "1"}, worker, *arguments)
      assert_predicate status, :success?, output
      expected = rows.group_by(&:first).values.each_with_index.flat_map do |cases, index|
        traps = cases.count { |row| %w[zero overflow].include?(row.last) }
        ["MIR JIT function #{index}: compiled"] + ["MIR JIT function #{index}: interpreter bailout"] * traps
      end
      assert_equal expected, output.lines.grep(/^MIR JIT function /).map(&:chomp)
    end
  end

  test "native i64 memory, globals and EH preserve signed register bits" do
    run_worker("efflorescence_m4_vectors", "M4 vectors passed", STORE_EH_WAT, STORE_EH_ROWS)
  end

  test "native i64 host calls, indirect calls and reentry" do
    run_worker("efflorescence_m4_host", "M4 host calls passed", HOST_WAT)
  end

  private

  def run_worker(source, expected, wat = nil, rows = nil)
    omit "Run make spinel-test to test the native executable" unless ENV["WARDITE_SPINEL_BIN"]
    root = File.expand_path("../..", __dir__)
    Dir.mktmpdir("wardite-spinel-m4") do |dir|
      worker = File.join(dir, "worker")
      arguments = []
      if wat
        file = File.join(dir, "input.wasm")
        File.binwrite(file, compile_efflorescence_wat(wat))
        arguments << file
      end
      if rows
        vectors = File.join(dir, "vectors.txt")
        File.write(vectors, rows.map { |row| row.join(" ") }.join("\n") + "\n")
        arguments << vectors
      end
      output, status = Open3.capture2e(ENV.fetch("SPINEL", "spinel"), "--strict-require", "-O2",
        "-I#{root}/lib", File.join(root, "test/spinel/#{source}.rb"), "-o", worker)
      assert status.success?, output
      env = block_given? ? {"WARDITE_MIR_JIT" => "0"} : {}
      output, status = Open3.capture2e(env, worker, *arguments)
      assert status.success?, output
      assert_equal "#{expected}\n", output
      yield worker, arguments if block_given?
    end
  end
end
