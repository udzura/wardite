# frozen_string_literal: true

require "test_helper"
require_relative "../support/efflorescence_helper"
require_relative "../support/efflorescence_m3_cases"

class WarditeSpinelM3Test < Test::Unit::TestCase
  include EfflorescenceHelper

  test "native module and hash host imports share the ABI and live funcref table" do
    omit "Run make spinel-test to test the native executable" unless ENV["WARDITE_SPINEL_BIN"]
    root = File.expand_path("../..", __dir__)
    Dir.mktmpdir("wardite-spinel-m3") do |dir|
      file = File.join(dir, "indirect.wasm")
      worker = File.join(dir, "m3")
      wat = EfflorescenceM3Cases::INDIRECT_WAT.sub("(table", <<~WAT.strip)
        (memory 1)
        (func (export "read_host_byte") (result i32) i32.const 0 i32.load8_u)
        (table
      WAT
      File.binwrite(file, compile_efflorescence_wat(wat))
      output, status = Open3.capture2e(ENV.fetch("SPINEL", "spinel"), "--strict-require", "-O2",
        "-I#{root}/lib", File.join(root, "test/spinel/efflorescence_m3.rb"), "-o", worker)
      assert status.success?, output
      output, status = Open3.capture2e(worker, file)
      assert status.success?, output
      assert_equal "M3 host and indirect calls passed\n", output
    end
  end
end
