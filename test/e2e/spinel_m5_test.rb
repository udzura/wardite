# frozen_string_literal: true

require "test_helper"
require_relative "../support/efflorescence_helper"
require_relative "../support/efflorescence_m5_cases"

class WarditeSpinelM5Test < Test::Unit::TestCase
  include EfflorescenceHelper
  include EfflorescenceM5Cases

  test "mixed float host and indirect calls" do
    omit "Run make spinel-test to test the native executable" unless ENV["WARDITE_SPINEL_BIN"]
    Dir.mktmpdir("wardite-m5-host") do |dir|
      wat = File.read(File.expand_path("../fixtures/efflorescence/m5_host.wat", __dir__))
      wasm = File.join(dir, "host.wasm")
      File.binwrite(wasm, compile_efflorescence_wat(wat))
      run_worker("efflorescence_m5_host", "M5 float host and indirect calls passed", wasm)
    end
  end

  test "float Store and EH retain raw bits" do
    omit "Run make spinel-test to test the native executable" unless ENV["WARDITE_SPINEL_BIN"]
    Dir.mktmpdir("wardite-m5-store") do |dir|
      wat = File.read(File.expand_path("../fixtures/efflorescence/m5_store_eh.wat", __dir__))
      wasm = File.join(dir, "store.wasm")
      File.binwrite(wasm, compile_efflorescence_wat(wat))
      run_worker("efflorescence_m5_store_eh", "M5 float Store and EH passed", wasm)
    end
  end

  test "all float ALU and conversion operations match the bit vectors" do
    omit "Run make spinel-test to test the native executable" unless ENV["WARDITE_SPINEL_BIN"]
    Dir.mktmpdir("wardite-m5-alu") do |dir|
      wat, vectors = float_vectors(float_alu_cases + float_conversion_cases)
      wasm = File.join(dir, "alu.wasm")
      expected = File.join(dir, "vectors.txt")
      File.binwrite(wasm, compile_efflorescence_wat(wat))
      File.write(expected, vectors)
      run_worker("efflorescence_m5_vectors", "M5 vectors passed", wasm, expected) do |worker|
        next unless ENV["WARDITE_MIR_JIT"] == "1" && RUBY_PLATFORM.match?(/arm64-darwin/)

        output, status = Open3.capture2e({"WARDITE_MIR_JIT" => "1", "WARDITE_TRACE" => "1"}, worker, wasm, expected)
        assert_predicate status, :success?, output
        events = vectors.lines.each_with_index.flat_map do |row, index|
          calls = ["MIR JIT function #{index}: compiled"]
          calls << "MIR JIT function #{index}: interpreter bailout" if %w[invalid overflow].include?(row.split.last)
          calls
        end
        # Each optimization configuration runs once with and once without profiling.
        assert_equal events * 3, output.lines.grep(/^MIR JIT function /).map(&:chomp)
      end
    end
  end

  test "native float bit and rounding probes" do
    run_worker("efflorescence_m5_bits", "M5 float bit and rounding probes passed")
  end

  test "native float control and public API" do
    omit "Run make spinel-test to test the native executable" unless ENV["WARDITE_SPINEL_BIN"]
    Dir.mktmpdir("wardite-m5-control") do |dir|
      wasm = File.join(dir, "control.wasm")
      wat = File.expand_path("../fixtures/efflorescence/m5_control.wat", __dir__)
      output, status = Open3.capture2e("wasm-tools", "parse", wat, "-o", wasm)
      assert status.success?, output
      run_worker("efflorescence_m5_control", "M5 float control passed", wasm)
    end
  end

  private

  def run_worker(source, expected, *arguments)
    omit "Run make spinel-test to test the native executable" unless ENV["WARDITE_SPINEL_BIN"]
    root = File.expand_path("../..", __dir__)
    Dir.mktmpdir("wardite-spinel-m5") do |dir|
      worker = File.join(dir, "worker")
      output, status = Open3.capture2e(ENV.fetch("SPINEL", "spinel"), "--strict-require", "-O2",
        "-I#{root}/lib", File.join(root, "test/spinel/#{source}.rb"), "-o", worker)
      assert status.success?, output
      env = block_given? ? {"WARDITE_MIR_JIT" => "0"} : {}
      output, status = Open3.capture2e(env, worker, *arguments)
      assert status.success?, output
      assert_equal "#{expected}\n", output
      yield worker if block_given?
    end
  end
end
