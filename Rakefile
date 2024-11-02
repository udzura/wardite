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
  libdir = File.expand_path("../lib", __FILE__)

  GenAlu.execute(libdir + "/wardite/alu_i32.generated.rb", prefix: "i32", defined_ops: [
    :lts,
    :leu,
    :add,
    :sub,
    :const,
    :store,
  ])
end

task default: %i[test check]

