# frozen_string_literal: true

require_relative "measure_function_jit"
require "tmpdir"

# Usage: ruby benchmark/measure_i64_jit.rb [wardite binary] [rounds]
binary = File.expand_path(ARGV.fetch(0, File.join(__dir__, "../build/wardite")))
rounds = Integer(ARGV.fetch(1, "200000"))
abort "rounds must fit a nonnegative i32" unless rounds.between?(0, 0x7fffffff)
abort "Build the Spinel CLI first: #{binary}" unless File.executable?(binary)

Dir.mktmpdir("wardite-i64-jit") do |dir|
  wasm = File.join(dir, "i64_m4.wasm")
  abort "WAT compilation failed" unless system("wasm-tools", "parse", File.join(__dir__, "i64_m4.wat"), "-o", wasm)
  puts "export,rounds,seed,result_bits,off_median_ms,on_median_ms,speedup"
  %w[alu division].each do |name|
    bits, off, on = MeasureFunctionJIT.run(binary, name, [wasm, rounds.to_s, "123"], "I64")
    puts "%s,%d,123,%d,%.3f,%.3f,%.2f" % [name, rounds, bits, off, on, off / on]
  end
end
