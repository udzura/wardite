# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "shellwords"
require "tmpdir"

# Spinel's driver selects inputs and linker flags for the host. Keep its C
# compiler flags and splitter, and substitute the target's link inputs.
if ARGV.first == "cc"
  ARGV.shift
  target = ENV.fetch("WARDITE_ZIG_TARGET")
  host = ENV.fetch("WARDITE_SPINEL_HOST")
  runtime = ENV.fetch("WARDITE_SPINEL_RUNTIME")
  args = ARGV.map do |arg|
    if arg == "-Wl,-dead_strip" && target.include?("-linux-")
      "-Wl,--gc-sections"
    elsif arg.start_with?("#{host}/") && arg.end_with?(".a", ".o")
      relative = File.expand_path(arg).delete_prefix("#{host}/")
      input = File.join(runtime, relative)
      abort "Spinel target link input is missing: #{input}" unless File.file?(input)
      input
    else
      arg
    end
  end
  # Zig 0.17.1 leaves an empty a.o when Spinel probes the compiler version.
  args += ["-o", File::NULL] if args == ["--version"]
  exec ENV.fetch("ZIG"), "cc", "-target", target, *args
elsif ARGV.first == "ar"
  # Spinel's Makefile runs `$(AR_DET) ar rcs …`.
  exec ENV.fetch("ZIG"), "ar", *ARGV.drop(2)
end

# Keep this revision in sync with the Spinel job in runtime-tests.yml.
SPINEL_REF = "a2aa0522761482cd83c09fc289eb1e91609e433a"

def run(*command, **options)
  system(*command, **options, exception: true)
end

def unpack(archive, directory)
  return if File.directory?(directory)

  Dir.mktmpdir("spinel-source-", File.dirname(directory)) do |staging|
    source = File.join(staging, "source")
    Dir.mkdir(source)
    run("tar", "-xzf", archive, "--strip-components", "1", "-C", source)
    File.rename(source, directory)
  end
end

make, build_dir, glibc, macos, jobs, spinel_flags, *targets = ARGV
abort "spinel-zig requires a macOS build host" unless RUBY_PLATFORM.include?("darwin")
abort "ZIG_GLIBC and ZIG_MACOS must be version numbers (e.g. 2.28 and 13.0)" unless
  [glibc, macos].all? { |version| version.match?(/\A\d+\.\d+(?:\.\d+)?\z/) }
abort "ZIG_JOBS must be an integer from 1 to 64" unless jobs.match?(/\A\d+\z/) && (1..64).cover?(jobs.to_i)

supported_targets = {
  "aarch64-macos" => "aarch64-macos.#{macos}",
  "x86_64-linux" => "x86_64-linux-gnu.#{glibc}",
  "aarch64-linux" => "aarch64-linux-gnu.#{glibc}"
}
if targets.empty? || (targets - supported_targets.keys).any?
  abort "ZIG_TARGETS must select from: #{supported_targets.keys.join(" ")}"
end

root = File.join(File.expand_path(build_dir), "spinel-zig")
FileUtils.mkdir_p(root)
root = File.realpath(root)
ENV["ZIG_GLOBAL_CACHE_DIR"] ||= File.join(root, "zig-global")
ENV["ZIG_LOCAL_CACHE_DIR"] ||= File.join(root, "zig-local")
run(ENV.fetch("ZIG"), "version")

File.open(File.join(root, "build.lock"), "a") do |lock|
  lock.flock(File::LOCK_EX)
  archive = File.join(root, "spinel-#{SPINEL_REF}.tar.gz")
  unless File.file?(archive)
    Dir.mktmpdir("spinel-download-", root) do |staging|
      download = File.join(staging, "spinel.tar.gz")
      url = "https://codeload.github.com/matz/spinel/tar.gz/#{SPINEL_REF}"
      run("curl", "-fLsS", "--retry", "2", "--max-time", "120", url, "-o", download)
      File.rename(download, archive)
    end
  end

  host = File.join(root, "host-#{SPINEL_REF}")
  unpack(archive, host)
  spinel = File.join(host, "bin", "spinel")
  inputs = ["lib/libspinel_rt_mt.a", "packages/stringio/sp_stringio_mt.o"]
  submake = [make, "-j#{jobs}", "NO_CCACHE=1"]
  make_env = {"MAKEFLAGS" => nil, "MFLAGS" => nil}
  run(make_env, *submake, "-C", host, "deps")
  run(make_env, *submake, "-C", host, "bin/spinel", *inputs)

  script = [RbConfig.ruby, File.expand_path(__FILE__)]
  cc = Shellwords.join([*script, "cc"])
  ar = Shellwords.join([*script, "ar"])
  targets.uniq.each do |name|
    target = supported_targets.fetch(name)
    output = File.join(root, target)
    FileUtils.mkdir_p(output)
    runtime = File.join(output, "spinel-#{SPINEL_REF}")
    unpack(archive, runtime)
    env = {
      "WARDITE_ZIG_TARGET" => target,
      "WARDITE_SPINEL_HOST" => host,
      "WARDITE_SPINEL_RUNTIME" => runtime
    }
    puts "Building Wardite for #{target}"
    run(make_env.merge(env), *submake, "-C", runtime, "CC=#{cc}", "AR_DET=#{ar}", *inputs)
    Dir.mktmpdir("wardite-", output) do |staging|
      binary = File.join(staging, "wardite")
      run(env, spinel, "-I", "lib", "--strict-require", *Shellwords.split(spinel_flags),
          "--cc=#{cc}", "--jobs=#{jobs}", "--split-parts=#{[jobs.to_i * 3, 64].min}",
          "exe/wardite", "-o", binary)
      File.rename(binary, File.join(output, "wardite"))
    end
    puts File.join(output, "wardite")
  end
end
