# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_manifest"

class EfflorescenceManifestTest < Test::Unit::TestCase
  test "M0 opcode manifest matches the historical target and current stack routes" do
    manifest = EfflorescenceManifest.rows
    assert_equal 191, manifest.size
    %w[opcode wasm decoder].each do |field|
      assert_equal 191, manifest[field].uniq.size, "duplicate #{field}"
    end
    legacy, extra = manifest.partition { |row| row["phase"] != "M1-EH" }
    assert_equal 188, legacy.size
    assert_equal EfflorescenceManifest.m0_opcodes, legacy.map { |row| row.values_at("opcode", "wasm", "phase") }
    assert_equal EfflorescenceManifest::EH, extra.to_h { |row| row.values_at("opcode", "wasm") }
    assert_equal legacy.map { |row| row["decoder"].to_sym }.sort, EfflorescenceManifest.stack_routes.sort
    manifest.each do |row|
      assert_equal row["decoder"].to_sym, EfflorescenceManifest.decode(row["opcode"])
      next if %w[source frame].include?(row["mir"])
      assert_include Wardite::Efflorescence::Opcode::NAMES, row["mir"], row["wasm"]
    end
  end
end
