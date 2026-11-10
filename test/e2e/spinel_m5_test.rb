# frozen_string_literal: true

require "test_helper"
require_relative "../support/efflorescence_helper"
require_relative "../support/efflorescence_m5_cases"

class WarditeSpinelM5Test < Test::Unit::TestCase
  include EfflorescenceHelper
  include EfflorescenceM5Cases

  test "all float ALU operations match the bit vectors" do
    omit "Run make spinel-test to test the native executable" unless ENV["WARDITE_SPINEL_BIN"]
    Dir.mktmpdir("wardite-m5-alu") do |dir|
      wat, vectors = float_vectors(float_alu_cases)
      wasm = File.join(dir, "alu.wasm")
      expected = File.join(dir, "vectors.txt")
      File.binwrite(wasm, compile_efflorescence_wat(wat))
      File.write(expected, vectors)
      run_worker("efflorescence_m5_vectors", "M5 vectors passed", wasm, expected)
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
      output, status = Open3.capture2e(worker, *arguments)
      assert status.success?, output
      assert_equal "#{expected}\n", output
    end
  end
end
