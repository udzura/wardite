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
      trunc__s: [:f32, :f64],
      trunc__u: [:f32, :f64],
      reinterpret: [:f32],
    },
    i64: {
      extend: [:i32_s, :i32_u],
      trunc__s: [:f32, :f64],
      trunc__u: [:f32, :f64],
      reinterpret: [:f64],
    },
    f32: {
      convert: [:i32_s, :i32_u, :i64_s, :i64_u],
      demote: [:f64],
      reinterpret: [:i32],
    },
    f64: {
      convert: [:i32_s, :i32_u, :i64_s, :i64_u],
      promote: [:f32],
      reinterpret: [:i64],
    },
  })
end

task default: %i[test check]

