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
    run_worker("efflorescence_m4_vectors", "M4 vectors passed", "(module #{functions})", rows)
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
      output, status = Open3.capture2e(worker, *arguments)
      assert status.success?, output
      assert_equal "#{expected}\n", output
    end
  end
end
