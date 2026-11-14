# frozen_string_literal: true

# Pass Wardite's normal CLI arguments. Run on CRuby outside timing samples.
require "json"
require "wardite"
require "wardite/cli/cli"

module FunctionCoverage
  DEFINED = {}
  CALLS = Hash.new(0)

  def initialize(function, *args)
    @coverage_index = function.index
    DEFINED[@coverage_index] = true
    super
  end

  def acquire(destination)
    CALLS[@coverage_index] += 1
    super
  end
end

Wardite::Efflorescence::FramePool.prepend(FunctionCoverage)
at_exit do
  calls = FunctionCoverage::CALLS.values.sort.reverse
  total = calls.sum
  cumulative = 0
  hot = calls.take_while do |count|
    more = cumulative * 10 < total * 9
    cumulative += count
    more
  end
  warn JSON.generate(defined: FunctionCoverage::DEFINED.size, used: calls.size,
    calls: total, functions_for_ninety_percent: hot.size)
end
Wardite::Cli::Cli.new(ARGV).run
