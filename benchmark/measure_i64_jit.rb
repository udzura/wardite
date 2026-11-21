# frozen_string_literal: true

require "open3"
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
    args = [wasm, rounds.to_s, "123"]
    ref, err, status = Open3.capture3("wasmtime", "run", "--invoke", name, *args)
    abort err unless status.success?
    bits = Integer(ref) % (1 << 64)
    expected = "return value: I64(#{bits})"
    command = [binary, "--no-wasi", "--invoke", name, "--", *args]
    output, status = Open3.capture2e({"WARDITE_MIR_JIT" => "1", "WARDITE_TRACE" => "1"}, *command)
    events = output.lines.grep(/^MIR JIT function /)
    abort "JIT did not complete #{name}: #{output}" unless events.size == 1 && events.first.match?(/: compiled$/)
    abort output unless status.success? && output.lines.map(&:chomp).include?(expected)

    # Alternate the order within each pair. Include process startup, loading,
    # compilation and the native call. Discard two warmup pairs.
    samples = [[], []]
    11.times do |pair|
      (pair.even? ? [0, 1] : [1, 0]).each do |jit|
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        output, status = Open3.capture2e({"WARDITE_MIR_JIT" => jit.to_s, "WARDITE_TRACE" => nil}, *command)
        ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
        abort output unless status.success? && output.chomp == expected
        samples[jit] << ms if pair >= 2
      end
    end
    off, on = samples.map { |values| values.sort.fetch(values.size / 2) }
    puts "%s,%d,123,%d,%.3f,%.3f,%.2f" % [name, rounds, bits, off, on, off / on]
  end
end
