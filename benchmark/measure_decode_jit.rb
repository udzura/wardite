# frozen_string_literal: true

# Keep the original decode benchmark invocation.
ARGV.unshift("decode")
require_relative "measure_base64_jit"
