# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

desc "Verify Efflorescence opcode parity with CRuby, Spinel and Wasmtime"
task :parity do
  sh "bundle exec ruby -Ilib test/support/run_efflorescence_manifest.rb"
end

desc "Run rbs-inline and steep"
task :check do
  sh "bundle exec rbs-inline --output lib/"
  sh "bundle exec steep check"
end

desc "Compile wat"
task :wasm, [:name] do |t, args|
  Dir.chdir "examples" do
    sh "wat2wasm #{args.name}.wat"
  end
end

desc "Run the official spec"
task :spec, [:name] do |t, args|
  sh "which git && git clean -xf spec/ || true"

  Dir.chdir "spec" do
    sh "curl -L -o ./#{args.name}.wast https://raw.githubusercontent.com/WebAssembly/spec/refs/tags/wg-1.0/test/core/#{args.name}.wast"
    sh "wast2json ./#{args.name}.wast"
    sh "env JSON_PATH=./#{args.name}.json ruby ./runner.rb -v"

    if File.exist?("./skip.txt")
      puts
      puts "\e[1;36mSkipped tests:\e[0m"
      puts IO.read("./skip.txt")
    end
  end
end

desc "Run basic benchmark"
task :basic_benchmark do
  sh "wasm-tools parse examples/i32_bench.wat -o examples/i32_bench.wasm"
  sh "hyperfine --warmup 3 'bundle exec wardite --yjit --no-wasi --invoke detailed_arithmetic_loop examples/i32_bench.wasm'"
end

task default: %i[test check]

