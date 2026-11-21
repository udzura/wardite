# frozen_string_literal: true

require_relative "measure_function_jit"

# Usage: ruby benchmark/measure_sieve_jit.rb [wardite binary] [count_primes.wasm]
binary = File.expand_path(ARGV.fetch(0, File.join(__dir__, "../build/wardite")))
examples = "../../wardite-benches/build/rust/wasm32-unknown-unknown/release/examples"
wasm = File.expand_path(ARGV.fetch(1, File.join(__dir__, examples, "count_primes.wasm")))
abort "Build the Spinel CLI first: #{binary}" unless File.executable?(binary)
abort "Pass the built wardite-benches count_primes.wasm as the second argument" unless File.file?(wasm)

puts "limit,prime_count,off_median_ms,on_median_ms,speedup"
[100, 1_000_000].each do |limit|
  result, off, on = MeasureFunctionJIT.run(binary, "count_primes_sieve", [wasm, limit.to_s], "I32") do |events|
    %w[load8_u store8].all? do |op|
      events.any? { |event| event.include?("byte loop") && event.include?("native exit") && event.chomp.end_with?("(#{op})") }
    end
  end
  puts "%d,%d,%.3f,%.3f,%.2f" % [limit, result, off, on, off / on]
end
