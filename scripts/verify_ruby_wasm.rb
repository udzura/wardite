# frozen_string_literal: true

require "digest"
require "open3"
require "rbconfig"
require "tmpdir"

wasm = File.expand_path(ARGV.fetch(0) { abort "Usage: ruby #{$PROGRAM_NAME} RUBY.wasm" })
root = File.expand_path("..", __dir__)
wardite = [RbConfig.ruby, "-I#{root}/lib", "#{root}/exe/wardite", "--new-engine"]
spinel = ENV["WARDITE_SPINEL_BIN"]
native = [File.expand_path(spinel), "--new-engine"] if spinel

puts "Ruby WASM SHA-256 #{Digest::SHA256.file(wasm).hexdigest}"
Dir.mktmpdir("wardite-ruby-wasm") do |workdir|
  app_dir = File.join(workdir, "app")
  Dir.mkdir(app_dir)
  File.write(File.join(app_dir, "main.rb"), "require_relative 'answer'\nputs ANSWER\n")
  File.write(File.join(app_dir, "answer.rb"), "ANSWER = 42\n")
  cases = [
    ["-e", [], [], ["-e", "puts RUBY_VERSION; puts 6*7"], "4.0.9\n42\n", 0],
    ["require_relative", ["--dir", "#{app_dir}::/app"], ["--mapdir", "#{app_dir}:/app"], ["/app/main.rb"], "42\n", 0],
    ["exit 7", [], [], ["-e", "exit 7"], "", 7],
  ]
  cases.each_with_index do |(name, reference_options, wardite_options, arguments, expected, expected_exit), index|
    guest_args = [wasm, "--disable-gems", *arguments]
    commands = [
      ["Wasmtime", ["wasmtime", "run", *reference_options, *guest_args]],
      ["Efflorescence", [*wardite, *wardite_options, "--", *guest_args]],
    ]
    commands << ["Spinel Efflorescence", [*native, *wardite_options, "--", *guest_args]] if native
    if ENV["WARDITE_VERIFY_MIR_CACHE"] == "1"
      engines = [["Efflorescence", wardite, "cruby-cache"]]
      engines << ["Spinel Efflorescence", native, "spinel-cache"] if native
      engines.each do |name, engine, cache|
        cached = [*engine, "--mir-cache", File.join(workdir, cache), *wardite_options, "--", *guest_args]
        commands << ["#{name} (cache miss)", cached, "miss"] if index.zero?
        commands << ["#{name} (cache hit)", cached, "hit"]
      end
    end
    commands.each do |runtime, command, cache_status|
      env = cache_status ? {"WARITE_TRACE" => "1"} : {}
      stdout, stderr, status = if defined?(Bundler)
        Bundler.with_original_env { Open3.capture3(env, *command) }
      else
        Open3.capture3(env, *command)
      end
      unless stdout == expected && status.exitstatus == expected_exit
        abort "#{runtime} #{name}: #{status.inspect}, stdout=#{stdout.inspect}\n#{stderr}"
      end
      if cache_status && !stderr.include?("MIR2 cache #{cache_status}:")
        abort "#{runtime} #{name}: expected cache #{cache_status}\n#{stderr}"
      end
    end
    puts "#{name} matched Wasmtime (exit #{expected_exit})"
  end
end
