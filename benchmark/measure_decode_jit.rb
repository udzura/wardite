# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "tmpdir"

# Optional third argument: bulk.wasm from wardite-benches/benchmark/base64-decode/instrument.py.
binary = File.expand_path(ARGV.fetch(0, File.join(__dir__, "../build/wardite")))
benches = File.expand_path(ARGV.fetch(1, File.join(__dir__, "../../wardite-benches")))
original = File.join(benches, "build/rust/wasm32-wasip1/release/examples/base64_codec.wasm")
bulk = ARGV[2]
env = {"WARDITE_TRACE" => nil, "WARDITE_MIR_WORKERS" => "8"}

puts "fixture,interval,off_ms,on_ms,speedup,iwasm_ms,wasmtime_ms,output_sha256"
Dir.mktmpdir do |dir|
  tiny = File.join(dir, "1k")
  File.binwrite(tiny, File.binread(File.join(benches, "build/fixtures/data.bin"), 1024))
  File.binwrite(tiny + ".b64", Base64.strict_encode64(File.binread(tiny)))
  fixtures = {"1KiB" => tiny, "256KiB" => File.join(benches, "build/fixtures/data"),
              "4MiB" => File.join(benches, "build/fixtures/data-4m")}
  output = File.join(dir, "output.bin")
  log = File.join(dir, "stderr")
  fixtures.each do |label, stem|
    input = stem + ".b64"
    expected = label == "1KiB" ? tiny : stem + ".bin"
    system(env.merge("WARDITE_MIR_JIT" => "1", "WARDITE_TRACE" => "1"), binary, "--", original, "decode",
      in: input, out: output, err: log, exception: true)
    events = File.readlines(log).grep(/MIR JIT lookup loop/)
    if label == "1KiB"
      abort "Unexpected native lookup loop on short input" unless events.empty?
    else
      abort "Expected the decode loop to finish natively" unless events.size == 1 && events.first.include?("native exit 400,")
    end

    [original, bulk].compact.each do |wasm|
      wardite = [binary, "--", wasm, "decode"]
      commands = [[env.merge("WARDITE_MIR_JIT" => "0"), *wardite], [env.merge("WARDITE_MIR_JIT" => "1"), *wardite],
                  ["iwasm", "--interp", wasm, "decode"], ["wasmtime", "run", "-C", "cache=n", "--", wasm, "decode"]]
      samples = commands.map { [] }
      11.times do |round|
        (round.even? ? [0, 1, 2, 3] : [3, 2, 1, 0]).each do |i|
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
          system(*commands.fetch(i), in: input, out: output, err: log, exception: true)
          ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - start
          if wasm == bulk
            record = File.binread(log)
            abort "Expected twelve WASI timestamps" unless record.bytesize == 96
            stamps = record.unpack("Q<12")
            ns = stamps.fetch(5) - stamps.fetch(4)
            abort "Missing decode loop timestamps" unless stamps.fetch(4) > 0 && ns > 0
          end
          abort "Decoded bytes differ for #{label}" unless FileUtils.compare_file(output, expected)
          samples.fetch(i) << ns / 1e6 if round >= 2
        end
      end
      off, on, iwasm, wasmtime = samples.map { |s| s.sort.fetch(s.size / 2) }
      puts "%s,%s,%.3f,%.3f,%.2f,%.3f,%.3f,%s" % [
        label, wasm == bulk ? "32-symbol loop" : "process", off, on, off / on, iwasm, wasmtime, Digest::SHA256.file(expected)]
    end
  end
end
