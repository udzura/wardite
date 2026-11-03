# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "shellwords"

root = File.expand_path("..", __dir__)
Dir.chdir(root)
rounds = Integer(ARGV.fetch(0, "100000"), 10)
seed = Integer(ARGV.fetch(1, "123456789"), 10)
abort "usage: ruby benchmark/compare.rb [rounds: 0..2147483647] [seed: 0..4294967295]" unless
  (0..2147483647).cover?(rounds) && (0..4294967295).cover?(seed)

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

runners = {
  "CRuby" => [RbConfig.ruby, "--disable-yjit", "-Ilib", "exe/wardite"],
  "CRuby + YJIT" => [RbConfig.ruby, "--yjit", "-Ilib", "exe/wardite"],
  "Spinel" => ["./build/wardite"],
  "WAMR (Interp)" => ["iwasm", "--interp"],
  "Wasmtime (Pulley)" => ["wasmtime", "run", "--target", "pulley64", "-C", "cache=n"],
  "Wasmtime" => ["wasmtime", "run", "-C", "cache=n"]
}
# Refuse to label an interpreted run as YJIT on a Ruby built without it.
output, status = Open3.capture2e(RbConfig.ruby, "--yjit", "-e", "abort 'YJIT unavailable' unless defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?")
abort output unless status.success?

commands = []
%w[inline_mix call_mix].each do |export|
  runners.each do |name, runner|
    if name =~ /Wasmtime/
      # Its CLI parses i32 arguments as signed values, with the same bits.
      signed_seed = seed >= 0x80000000 ? seed - 0x100000000 : seed
      command = runner + ["--invoke", export, wasm, rounds.to_s, signed_seed.to_s]
    elsif name =~ /WAMR/
      command = runner + ["-f", export, wasm, rounds.to_s, seed.to_s]
    else
      command = runner + ["--no-wasi", "--invoke", export, "--", wasm, rounds.to_s, seed.to_s]
    end
    stdout, stderr, status = Open3.capture3(*command)
    matches = case name
    when /Wasmtime/
      stdout.strip == signed.to_s
    when /WAMR/
      stdout.strip == "0x%x:i32" % signed
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
system("spinel", "--version")
system("wasmtime", "--version")
abort "Benchmark failed" unless system(
  "hyperfine", "--shell=none", "--warmup", "2", "--runs", "5",
  "--export-json", "build/benchmark/results.json", *commands
)
