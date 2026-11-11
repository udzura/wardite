# frozen_string_literal: true

require "csv"
require "wardite"

module EfflorescenceManifest
  ROOT = File.expand_path("../..", __dir__)
  PATH = File.join(__dir__, "efflorescence_opcodes.tsv")
  M0 = File.join(ROOT, "docs/efflorescence-coverage-ja.md")
  LEGACY_HANDLERS = %w[alu_i32 alu_i64 alu_f32 alu_f64 convert].map do |name|
    File.join(ROOT, "lib/wardite/#{name}.generated.rb")
  end.freeze
  EH = { "08" => "throw", "0a" => "throw_ref", "1f" => "try_table" }.freeze

  def self.rows
    CSV.read(PATH, headers: true, col_sep: "\t")
  end

  def self.m0_opcodes
    File.read(M0).scan(/^\| `([\da-f]{2}(?:\/[\da-f]{2})?)` \| `([\w.]+)` \| (既存|M[1-5]) \|/).map do |opcode, name, phase|
      [opcode, name, phase == "既存" ? "pre-M1" : phase]
    end
  end

  def self.decode(opcode)
    first, second = opcode.split("/").map { |byte| Integer(byte, 16) }
    second ? Wardite::Op::FC_SYMS.fetch(second) : Wardite::Op::SYMS.fetch(first)
  end

  # This checks the static baseline. Execution evidence is verified separately.
  def self.stack_routes
    runtime = File.read(File.join(ROOT, "lib/wardite.rb"))
      .split("def eval_insn", 2).last.split("\n  class ", 2).first
    handlers = LEGACY_HANDLERS.map { |path| File.read(path) } + [runtime]
    names = handlers.flat_map { |source| source.scan(/^\s*when :(\w+)/).flatten.map(&:to_sym) }
    names.uniq & (Wardite::Op::SYMS + Wardite::Op::FC_SYMS)
  end
end
