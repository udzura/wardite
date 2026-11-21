# frozen_string_literal: true

require "fileutils"
require "open3"
require "optparse"
require "rbconfig"
require "shellwords"

skip_build = false
selected_wardite = nil
options = OptionParser.new do |opts|
  opts.banner = "Usage: ruby benchmark/compare.rb [options] [rounds: 0..2147483647] [seed: 0..4294967295]"
  opts.on("--skip-build", "Reuse build/wardite") { skip_build = true }
  opts.on("--wardite COMMAND", "Use an existing Wardite executable by name or path") do |command|
    selected_wardite = command
    skip_build = true
  end
end
begin
  options.permute!(ARGV)
rescue OptionParser::ParseError => e
  abort "#{e.message}\n#{options}"
end
wardite = "./build/wardite"
if selected_wardite
  candidates = if selected_wardite.include?(File::SEPARATOR)
    [selected_wardite]
  else
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR, -1).map { |dir| File.absolute_path(selected_wardite, dir.empty? ? "." : dir) }
  end
  path = candidates.find { |candidate| File.file?(candidate) && File.executable?(candidate) }
  abort "Cannot find executable Wardite: #{selected_wardite.inspect}" unless path
  wardite = File.absolute_path(path)
end
Dir.chdir(File.expand_path("..", __dir__))
rounds = Integer(ARGV.fetch(0, "100000"), 10)
seed = Integer(ARGV.fetch(1, "123456789"), 10)
runs = Integer(ENV.fetch("RUNS", "5"), 10)
warmups = Integer(ENV.fetch("WARMUPS", "2"), 10)
abort options.to_s unless ARGV.size <= 2 && (0..2147483647).cover?(rounds) && (0..4294967295).cover?(seed)
abort "RUNS must be positive and WARMUPS must be nonnegative" unless runs > 0 && warmups >= 0

FileUtils.mkdir_p("build/benchmark")
wasm = "build/benchmark/i32_mix.wasm"
abort "WAT compilation failed" unless system("wasm-tools", "parse", "benchmark/i32_mix.wat", "-o", wasm)
if skip_build
  abort "--skip-build requires an executable #{wardite}. Run make spinel first." unless File.file?(wardite) && File.executable?(wardite)
  puts "Using existing #{wardite}."
else
  abort "Spinel build failed" unless system("make", "spinel")
end

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
  "Spinel" => ["env", "WARDITE_MIR_JIT=0", wardite]
}
runners = {}
wardite_runners.each do |runtime, command|
  runners["Efflorescence / #{runtime}"] = [:wardite, command]
end
if RUBY_PLATFORM.match?(/arm64-darwin/)
  runners["Efflorescence / Spinel + MIR JIT"] = [:wardite_jit, ["env", "WARDITE_MIR_JIT=1", wardite]]
else
  warn "Skipping the MIR JIT comparison (requires Apple Silicon macOS)."
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
verified = 0
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
    # Trace only the untimed JIT check so a fallback cannot pass as a JIT measurement.
    check_env = {"WARDITE_TRACE" => kind == :wardite_jit ? "1" : nil}
    stdout, stderr, status = Open3.capture3(check_env, *command)
    matches = case kind
    when :wasmtime
      stdout.strip == signed.to_s
    when :iwasm
      # iwasm prints the unsigned bit pattern, even when Wardite/Wasmtime
      # display the same i32 as a negative signed integer.
      stdout.strip == "0x%x:i32" % checksum
    when :wardite_jit
      jit_events = stderr.lines.grep(/^MIR JIT function /)
      if selected_wardite && jit_events.empty? && status.success? && stdout.empty? && stderr.lines.include?(expected)
        warn "Skipping #{name} / #{export}: #{wardite} did not report MIR JIT compilation."
        next
      end
      stdout.empty? && stderr.lines.include?(expected) &&
        jit_events.size == 1 && jit_events.first.match?(/: compiled$/)
    else
      stdout.empty? && stderr == expected
    end
    abort "#{name}/#{export} failed: stdout=#{stdout.inspect}, stderr=#{stderr.inspect}" unless status.success? && matches
    commands.concat(["--command-name", "#{name} / #{export}", Shellwords.join(command)])
    verified += 1
  end
end
puts "Verified all #{verified} results against reference: I32(#{signed}) (rounds=#{rounds}, seed=#{seed})"
puts "Timing whole CLI processes, including startup and module loading (Wasmtime cache off, compilation included)."
version, = Open3.capture2e(RbConfig.ruby, "--version")
puts "CRuby: #{version.strip}"
versions = {"Wasmtime" => ["wasmtime"], "iwasm" => ["iwasm"]}
versions["Spinel"] = Shellwords.split(ENV.fetch("SPINEL", "spinel")) unless skip_build
versions.each do |name, command|
  output, status = Open3.capture2e(*command, "--version")
  abort "Cannot identify #{name}: #{output}" unless status.success?
  puts "#{name}: #{output.lines.first.to_s.strip}"
end
abort "Benchmark failed" unless system(
  {"WARDITE_TRACE" => nil},
  "hyperfine", "--shell=none", "--warmup", warmups.to_s, "--runs", runs.to_s,
  "--export-json", "build/benchmark/results.json", *commands
)
