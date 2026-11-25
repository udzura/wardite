# frozen_string_literal: true

require "strscan"

module CoreSpec
  # WABT sometimes points inside an assertion (e.g. at its nested module).
  # Retain complete top-level forms from the original, before NaN normalization.
  Form = Data.define(:first_line, :last_line, :text)

  def self.source_forms(source)
    scanner = StringScanner.new(source)
    forms = []
    depth = comments = 0
    line = 1
    start = first_line = nil
    until scanner.eos?
      offset = scanner.pos
      token = if comments.positive?
        scanner.scan(/\(;|;\)|[^();]+|./m)
      else
        scanner.scan(/;;[^\n]*|\(;|"(?:\\.|[^"\\])*"|[()]|[^();"\n]+|./m)
      end
      if token == "(;"
        comments += 1
      elsif comments.positive?
        comments -= 1 if token == ";)"
      elsif token == "("
        start, first_line = offset, line if depth.zero?
        depth += 1
      elsif token == ")"
        depth -= 1
        forms << Form.new(first_line, line, source.byteslice(start...scanner.pos)) if depth.zero?
      end
      line += token.count("\n")
    end
    forms
  end
end
