# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "shellwords"

root = File.expand_path("..", __dir__)
Dir.chdir(root)
rounds = Integer(ARGV.fetch(0, "100000"), 10)
seed = Integer(ARGV.fetch(1, "123456789"), 10)
runs = Integer(ENV.fetch("RUNS", "5"), 10)
warmups = Integer(ENV.fetch("WARMUPS", "2"), 10)
abort "usage: ruby benchmark/compare.rb [rounds: 0..2147483647] [seed: 0..4294967295]" unless
  (0..2147483647).cover?(rounds) && (0..4294967295).cover?(seed)
abort "RUNS must be positive and WARMUPS must be nonnegative" unless runs > 0 && warmups >= 0

FileUtils.mkdir_p("build/benchmark")
wasm = "build/benchmark/i32_mix.wasm"
abort "WAT compilation failed" unless system("wasm-tools", "parse", "benchmark/i32_mix.wat", "-o", wasm)
abort "Spinel build failed" unless system("make", "spinel")

# Independent reference with explicit Wasm i32 wrapping after each operation.
checksum = seed
rounds.times do
  checksum ^= checksum >> 13
  checksum = (checksum * 1664525 + 1013904223) & 0xffffffff
  checksum = (checksum ^ (checksum << 7)) & 0xffffffff
end
signed = checksum >= 0x80000000 ? checksum - 0x100000000 : checksum
expected = "return value: I32(#{signed})\n"

wardite_runners = {
  # "CRuby" => [RbConfig.ruby, "--disable-yjit", "-Ilib", "exe/wardite"],
  # "CRuby + YJIT" => [RbConfig.ruby, "--yjit", "-Ilib", "exe/wardite"],
  "Spinel" => ["./build/wardite"]
}
runners = {}
wardite_runners.each do |runtime, command|
  # runners["Old VM / #{runtime}"] = [:wardite, command]
  runners["New VM / #{runtime}"] = [:wardite, command + ["--new-engine"]]
end
runners["iwasm (WAMR interpreter)"] = [:iwasm, ["iwasm", "--interp"]]
runners["Wasmtime (Pulley)"] = [:wasmtime, ["wasmtime", "run", "--target", "pulley64", "-C", "cache=n"]]
runners["Wasmtime"] = [:wasmtime, ["wasmtime", "run", "-C", "cache=n"]]
# Refuse to label an interpreted run as YJIT on a Ruby built without it.
if wardite_runners.key?("CRuby + YJIT")
  output, status = Open3.capture2e(RbConfig.ruby, "--yjit", "-e", "abort 'YJIT unavailable' unless defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?")
  abort output unless status.success?
end

commands = []
%w[inline_mix call_mix].each do |export|
  runners.each do |name, (kind, runner)|
    command = case kind
    when :wasmtime
      # Its CLI parses i32 arguments as signed values, with the same bits.
      signed_seed = seed >= 0x80000000 ? seed - 0x100000000 : seed
      runner + ["--invoke", export, wasm, rounds.to_s, signed_seed.to_s]
    when :iwasm
      runner + ["-f", export, wasm, rounds.to_s, seed.to_s]
    else
      runner + ["--no-wasi", "--invoke", export, "--", wasm, rounds.to_s, seed.to_s]
    end
    stdout, stderr, status = Open3.capture3(*command)
    matches = case kind
    when :wasmtime
      stdout.strip == signed.to_s
    when :iwasm
      # iwasm prints the unsigned bit pattern, even when Wardite/Wasmtime
      # display the same i32 as a negative signed integer.
      stdout.strip == "0x%x:i32" % checksum
    else
      stdout.empty? && stderr == expected
    end
    abort "#{name}/#{export} failed: stdout=#{stdout.inspect}, stderr=#{stderr.inspect}" unless status.success? && matches
    commands.concat(["--command-name", "#{name} / #{export}", Shellwords.join(command)])
  end
end
puts "Verified all #{runners.size * 2} results against reference: I32(#{signed}) (rounds=#{rounds}, seed=#{seed})"
puts "Timing whole CLI processes, including startup and module loading (Wasmtime cache off, compilation included)."
version, = Open3.capture2e(RbConfig.ruby, "--version")
puts "CRuby: #{version.strip}"
{"Spinel" => Shellwords.split(ENV.fetch("SPINEL", "spinel")),
 "Wasmtime" => ["wasmtime"], "iwasm" => ["iwasm"]}.each do |name, command|
  output, status = Open3.capture2e(*command, "--version")
  abort "Cannot identify #{name}: #{output}" unless status.success?
  puts "#{name}: #{output.lines.first.to_s.strip}"
end
abort "Benchmark failed" unless system(
  "hyperfine", "--shell=none", "--warmup", warmups.to_s, "--runs", runs.to_s,
  "--export-json", "build/benchmark/results.json", *commands
)
