# frozen_string_literal: true

require "test_helper"

class WarditeSpinelM5Test < Test::Unit::TestCase
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
