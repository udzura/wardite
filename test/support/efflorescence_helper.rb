# frozen_string_literal: true

require "open3"

module EfflorescenceHelper
  MIX_WAT = File.expand_path("../../benchmark/i32_mix.wat", __dir__)
  MIX_CASES = [[0, 0], [0, 123], [1, 0], [1, 123], [10, 123],
               [1000, 123], [1000, 0xffffffff], [100000, 123]].freeze

  # Independent arithmetic reference: modulo rather than MIR register operations.
  def reference_mix(rounds, seed)
    x = seed % (2**32)
    rounds.times do
      x ^= x / (2**13)
      x = (x * 1664525 + 1013904223) % (2**32)
      x = (x ^ (x * (2**7))) % (2**32)
    end
    x
  end

  def compile_efflorescence_wat(code)
    Dir.mktmpdir("wardite-efflorescence") do |dir|
      wat = File.join(dir, "input.wat")
      wasm = File.join(dir, "input.wasm")
      File.write(wat, code)
      output, status = Open3.capture2e("wasm-tools", "parse", wat, "-o", wasm)
      raise "WAT compilation failed: #{output}" unless status.success?
      File.binread(wasm)
    end
  end

  def load_efflorescence(code)
    Wardite::BinaryLoader.load_from_buffer(
      StringIO.new(compile_efflorescence_wat(code)), enable_wasi: false, engine: :efflorescence
    )
  end
end
