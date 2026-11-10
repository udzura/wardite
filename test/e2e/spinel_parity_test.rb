# frozen_string_literal: true

require "test_helper"
require_relative "../support/efflorescence_parity"

require_relative "../support/efflorescence_helper"
require_relative "../support/efflorescence_invalid_cases"

class WarditeSpinelParityTest < Test::Unit::TestCase
  include EfflorescenceHelper
  include EfflorescenceInvalidCases

  test "reject invalid i32 immediates and unreferenced globals" do
    binary = ENV["WARDITE_SPINEL_BIN"]
    omit "Run make spinel-test to test the native executable" unless binary
    malformed_numeric_fixtures.each do |bytes, reason|
      Dir.mktmpdir("wardite-native-invalid") do |directory|
        wasm = File.join(directory, "invalid.wasm")
        File.binwrite(wasm, bytes)
        [[], ["--new-engine"]].each do |options|
          output, status = Open3.capture2e(binary, *options, "--no-wasi", "--invoke", "missing", wasm)
          assert_false status.success?, output
          assert_include output, reason
        end
      end
    end
  end

  test "native parity runner compares state and the position of a trap" do
    omit "Run make spinel-test to test the native executable" unless ENV["WARDITE_SPINEL_BIN"]
    assert_nothing_raised do
      EfflorescenceParity.run([EfflorescenceParity.state_fixture], runtime: :spinel)
    end
  end
end
