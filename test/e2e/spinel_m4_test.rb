# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

class WarditeSpinelM4Test < Test::Unit::TestCase
  test "native i64 decode, registers and boxing preserve all bits" do
    omit "Run make spinel-test to test the native executable" unless ENV["WARDITE_SPINEL_BIN"]
    root = File.expand_path("../..", __dir__)
    Dir.mktmpdir("wardite-spinel-m4") do |dir|
      worker = File.join(dir, "m4-values")
      output, status = Open3.capture2e(ENV.fetch("SPINEL", "spinel"), "--strict-require", "-O2",
        "-I#{root}/lib", File.join(root, "test/spinel/efflorescence_m4_values.rb"), "-o", worker)
      assert status.success?, output
      output, status = Open3.capture2e(worker)
      assert status.success?, output
      assert_equal "M4 signed registers passed\n", output
    end
  end
end
