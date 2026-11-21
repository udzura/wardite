# frozen_string_literal: true

require "tmpdir"
require_relative "measure_function_jit"

# Usage: ruby benchmark/measure_float_jit.rb [wardite binary] [wardite-benches mandelbrot.wasm]
binary = File.expand_path(ARGV.fetch(0, File.join(__dir__, "../build/wardite")))
examples = "../../wardite-benches/build/rust/wasm32-unknown-unknown/release/examples"
mandelbrot = File.expand_path(ARGV.fetch(1, File.join(__dir__, examples, "mandelbrot.wasm")))
abort "Build the Spinel CLI first: #{binary}" unless File.executable?(binary)
abort "Pass the built wardite-benches mandelbrot.wasm as the second argument" unless File.file?(mandelbrot)

Dir.mktmpdir("wardite-float-jit") do |dir|
  wasm = File.join(dir, "float_m5.wasm")
  abort "WAT compilation failed" unless system("wasm-tools", "parse", File.join(__dir__, "float_m5.wat"), "-o", wasm)
  puts "export,arguments,result,off_median_ms,on_median_ms,speedup"
  [
    ["float_alu", wasm, %w[200000 123], "I64"],
    ["float_convert", wasm, %w[200000 123], "I64"],
    ["mandelbrot_f32", mandelbrot, %w[200 150 100], "I32"],
    ["mandelbrot_f64", mandelbrot, %w[200 150 100], "I32"]
  ].each do |name, path, args, result_type|
    result, off, on = MeasureFunctionJIT.run(binary, name, [path, *args], result_type)
    puts "%s,%s,%d,%.3f,%.3f,%.2f" % [name, args.join(" "), result, off, on, off / on]
  end
end
