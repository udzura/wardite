# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"

# Usage: ruby benchmark/measure_png_jit.rb [wardite binary] [wardite-benches directory] [timed unfilter Wasm]
binary = File.expand_path(ARGV.fetch(0, File.join(__dir__, "../build/wardite")))
benches = File.expand_path(ARGV.fetch(1, File.join(__dir__, "../../wardite-benches")))
wasm = File.join(benches, "build/rust/wasm32-wasip1/release/examples/png_grayscale.wasm")
timed = ARGV[2]
wardite = [binary, "--", timed || wasm]
env = {"WARDITE_TRACE" => nil, "WARDITE_MIR_WORKERS" => "8"}
commands = [
  [env.merge("WARDITE_MIR_JIT" => "0"), *wardite], [env.merge("WARDITE_MIR_JIT" => "1"), *wardite],
  ["iwasm", "--interp", timed || wasm], ["wasmtime", "run", "-C", "cache=n", "--", timed || wasm]
]

puts "fixture,off_ms,on_ms,speedup,iwasm_ms,wasmtime_ms,pgm_sha256"
Dir.mktmpdir do |dir|
  output = File.join(dir, "output.pgm")
  reference = File.join(dir, "reference.pgm")
  %w[rgb.png rgb-1024.png].each do |fixture|
    input = File.join(benches, "build/fixtures", fixture)
    system("wasmtime", "run", "-C", "cache=n", "--", wasm, in: input, out: reference, exception: true)
    # Check both backedges in the original guest separately from timing.
    trace = File.join(dir, "trace.log")
    system(env.merge("WARDITE_MIR_JIT" => "1", "WARDITE_TRACE" => "1"), binary, "--", wasm,
      in: input, out: output, err: trace, exception: true)
    unless File.foreach(trace).any? { |line| line.include?("byte loop function 24: backedge 40, native exit 41 (store8)") }
      abort "Expected the ADR 0031 luma loop to run natively for #{fixture}. Check the binary and fixture revision."
    end
    unless File.foreach(trace).any? { |line| line.include?("byte-add loop function 115: backedge 661, native exit 662,") }
      abort "Expected the ADR 0031 Sub loop to run natively for #{fixture}."
    end
    samples = commands.map { [] }
    11.times do |round|
      # Alternate JIT on/off order, and alternate which pair of engines runs first.
      order = round.even? ? [0, 1, 2, 3] : [3, 2, 1, 0]
      order.each do |index|
        command = commands.fetch(index)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        system(*command, in: input, out: output, err: trace, exception: true)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        if timed
          records = File.binread(trace)
          rows = fixture == "rgb.png" ? 256 : 1024
          abort "Expected one timestamp pair per row" unless records.bytesize == rows * 16
          elapsed = records.unpack("Q<*").each_slice(2).sum do |first, last|
            abort "Invalid unfilter timestamps" unless last >= first && first > 0
            (last - first) / 1e9
          end
        end
        abort "PGM mismatch: #{fixture}, #{command.inspect}" unless FileUtils.compare_file(reference, output)
        samples.fetch(index) << elapsed * 1000 if round >= 2
      end
    end
    off, on, iwasm, wasmtime = samples.map { |times| times.sort.fetch(times.size / 2) }
    puts "%s,%.3f,%.3f,%.2f,%.3f,%.3f,%s" % [fixture, off, on, off / on, iwasm, wasmtime, Digest::SHA256.file(reference)]
  end
end
