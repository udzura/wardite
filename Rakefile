# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
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
  sh "hyperfine 'bundle exec wardite --yjit --no-wasi --invoke detailed_arithmetic_loop examples/i32_bench.wasm'"
end

desc "Generate codes"
task :generate do
  require_relative "scripts/gen_alu"
  require_relative "scripts/gen_conv"
  libdir = File.expand_path("../lib", __FILE__)

  GenAlu.execute(libdir + "/wardite/alu_i32.generated.rb", prefix: "i32", defined_ops: [
    :load,
    :load8_s,
    :load8_u,
    :load16_s,
    :load16_u,
    :store,
    :store8,
    :store16,
    :const,
    :eqz,
    :eq,
    :ne,
    :lts,
    :ltu,
    :gts,
    :gtu,
    :les,
    :leu,
    :ges,
    :geu,
    :clz,
    :ctz,
    :popcnt,
    :add,
    :sub,
    :mul,
    :div_s,
    :div_u,
    :rem_s,
    :rem_u,
    :and,
    :or,
    :xor,
    :shl,
    :shr_s,
    :shr_u,
    :rotl,
    :rotr,
  ])
  GenAlu.execute(libdir + "/wardite/alu_i64.generated.rb", prefix: "i64", defined_ops: [
    :load,
    :load8_s,
    :load8_u,
    :load16_s,
    :load16_u,
    :load32_s,
    :load32_u,
    :store,
    :store8,
    :store16,
    :store32,
    :const,
    :eqz,
    :eq,
    :ne,
    :lts,
    :ltu,
    :gts,
    :gtu,
    :les,
    :leu,
    :ges,
    :geu,
    :clz,
    :ctz,
    :popcnt,
    :add,
    :sub,
    :mul,
    :div_s,
    :div_u,
    :rem_s,
    :rem_u,
    :and,
    :or,
    :xor,
    :shl,
    :shr_s,
    :shr_u,
    :rotl,
    :rotr,
  ])
  GenAlu.execute(libdir + "/wardite/alu_f32.generated.rb", prefix: "f32", defined_ops: [
    :load,
    :store,
    :const__f,
    :eqz,
    :eq,
    :ne,
    :lt,
    :gt,
    :le,
    :ge,
    :abs,
    :neg,
    :ceil,
    :floor,
    :trunc,
    :nearest,
    :sqrt,
    :add,
    :sub,
    :mul,
    :div,
    :min,
    :max,
    :copysign,
  ])
  GenAlu.execute(libdir + "/wardite/alu_f64.generated.rb", prefix: "f64", defined_ops: [
    :load,
    :store,
    :const__f,
    :eqz,
    :eq,
    :ne,
    :lt,
    :gt,
    :le,
    :ge,
    :abs,
    :neg,
    :ceil,
    :floor,
    :trunc,
    :nearest,
    :sqrt,
    :add,
    :sub,
    :mul,
    :div,
    :min,
    :max,
    :copysign,
  ])

  GenConv.execute(libdir + "/wardite/convert.generated.rb", defined_ops: {
    i32: {
      wrap: [:i64],
      trunc_s: [:f32, :f64],
      trunc_u: [:f32, :f64],
      reinterpret: [:f32],
      extendN_s: [:i8, :i16],
      trunc_sat_s: [:f32, :f64],
      trunc_sat_u: [:f32, :f64],
    },
    i64: {
      extend_s: [:i32, :i64],
      extend_u: [:i32, :i64],
      trunc_s: [:f32, :f64],
      trunc_u: [:f32, :f64],
      reinterpret: [:f64],
      extendN_s: [:i8, :i16, :i32],
      trunc_sat_s: [:f32, :f64],
      trunc_sat_u: [:f32, :f64],
    },
    f32: {
      convert_s: [:i32, :i64],
      convert_u: [:i32, :i64],
      demote: [:f64],
      reinterpret: [:i32],
    },
    f64: {
      convert_s: [:i32, :i64],
      convert_u: [:i32, :i64],
      promote: [:f32],
      reinterpret: [:i64],
    },
  })
end

task default: %i[test check]

