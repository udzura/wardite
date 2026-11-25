# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "tmpdir"

# Usage: measure_base64_jit.rb encode|decode [wardite [wardite-benches [timed.wasm]]]
mode = ARGV.shift
abort "Expected encode or decode" unless %w[encode decode].include?(mode)
encode = mode == "encode"
binary = File.expand_path(ARGV.fetch(0, File.join(__dir__, "../build/wardite")))
benches = File.expand_path(ARGV.fetch(1, File.join(__dir__, "../../wardite-benches")))
original = File.join(benches, "build/rust/wasm32-wasip1/release/examples/base64_codec.wasm")
bulk = ARGV[2]
env = {"WARDITE_TRACE" => nil, "WARDITE_MIR_WORKERS" => "8"}

puts "fixture,interval,off_ms,on_ms,speedup,iwasm_ms,wasmtime_ms,output_sha256"
Dir.mktmpdir do |dir|
  tiny = File.join(dir, "1k")
  File.binwrite(tiny + ".bin", File.binread(File.join(benches, "build/fixtures/data.bin"), 1024))
  File.binwrite(tiny + ".b64", Base64.strict_encode64(File.binread(tiny + ".bin")))
  fixtures = {"1KiB" => tiny, "256KiB" => File.join(benches, "build/fixtures/data"),
              "4MiB" => File.join(benches, "build/fixtures/data-4m")}
  output = File.join(dir, "output.bin")
  log = File.join(dir, "stderr")
  fixtures.each do |label, stem|
    raw = stem + ".bin"
    input = encode ? raw : stem + ".b64"
    expected = raw
    if encode
      expected = File.join(dir, "expected.b64")
      File.binwrite(expected, Base64.strict_encode64(File.binread(raw)) + "\n")
    end
    system(env.merge("WARDITE_MIR_JIT" => "1", "WARDITE_TRACE" => "1"), binary, "--", original, mode,
      in: input, out: output, err: log, exception: true)
    events = File.readlines(log).grep(/MIR JIT lookup loop/)
    if label == "1KiB"
      abort "Unexpected native lookup loop on short input" unless events.empty?
    else
      exit_pc = encode ? 306 : 400
      abort "Expected the #{mode} loop to finish natively" unless events.size == 1 && events.first.include?("native exit #{exit_pc},")
    end

    [original, bulk].compact.each do |wasm|
      wardite = [binary, "--", wasm, mode]
      commands = [[env.merge("WARDITE_MIR_JIT" => "0"), *wardite], [env.merge("WARDITE_MIR_JIT" => "1"), *wardite],
                  ["iwasm", "--interp", wasm, mode], ["wasmtime", "run", "-C", "cache=n", "--", wasm, mode]]
      samples = commands.map { [] }
      11.times do |round|
        (round.even? ? [0, 1, 2, 3] : [3, 2, 1, 0]).each do |i|
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
          system(*commands.fetch(i), in: input, out: output, err: log, exception: true)
          ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - start
          if wasm == bulk
            record = File.binread(log)
            abort "Unexpected WASI timestamp record" unless record.bytesize == (encode ? 16 : 96)
            stamps = record.unpack("Q<*")
            first = encode ? 0 : 4
            ns = stamps.fetch(first + 1) - stamps.fetch(first)
            abort "Missing bulk loop timestamps" unless stamps.fetch(first) > 0 && ns > 0
          end
          abort "#{mode} bytes differ for #{label}" unless FileUtils.compare_file(output, expected)
          samples.fetch(i) << ns / 1e6 if round >= 2
        end
      end
      off, on, iwasm, wasmtime = samples.map { |s| s.sort.fetch(s.size / 2) }
      interval = encode ? "24-byte loop" : "32-symbol loop"
      puts "%s,%s,%.3f,%.3f,%.2f,%.3f,%.3f,%s" % [
        label, wasm == bulk ? interval : "process", off, on, off / on, iwasm, wasmtime, Digest::SHA256.file(expected)]
    end
  end
end
