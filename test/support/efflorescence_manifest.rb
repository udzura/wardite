# frozen_string_literal: true

require "csv"
require "wardite"

module EfflorescenceManifest
  ROOT = File.expand_path("../..", __dir__)
  PATH = File.join(__dir__, "efflorescence_opcodes.tsv")
  M0 = File.join(ROOT, "docs/efflorescence-coverage-ja.md")
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
end
