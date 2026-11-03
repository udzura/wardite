# frozen_string_literal: true

require "wardite"
require "wardite/cli/cli"

Wardite::Cli::Cli.new(ARGV).run
