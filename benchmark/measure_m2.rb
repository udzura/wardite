# frozen_string_literal: true

# Usage: RUNS=7 WARMUPS=2 ROUNDS=1000 bundle exec ruby benchmark/measure_m2.rb
require 'json'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'shellwords'

Dir.chdir(File.expand_path('..', __dir__))
runs = Integer(ENV.fetch('RUNS','7'))
warmups = Integer(ENV.fetch('WARMUPS','2'))
rounds = Integer(ENV.fetch('ROUNDS','1000'))
seed = Integer(ENV.fetch('SEED','123'))
abort 'invalid sample counts or i32 arguments' unless runs > 0 && warmups >= 0 && (0..0x7fffffff).cover?(rounds) && (0..0xffffffff).cover?(seed)
FileUtils.mkdir_p('build/benchmark')
binary = 'build/benchmark/i32_memory.wasm'
worker = ENV.fetch('M2_SPINEL_WORKER','build/benchmark/m2-worker')
compiler = Shellwords.split(ENV.fetch('SPINEL','spinel'))
flags = Shellwords.split(ENV.fetch('SPINELFLAGS','-O2'))
parse, status = Open3.capture2e('wasm-tools','parse','benchmark/i32_memory.wat','-o',binary)
abort parse unless status.success?
valid, status = Open3.capture2e('wasm-tools','validate',binary)
abort valid unless status.success?
unless ENV['M2_SPINEL_WORKER']
  log, status = Open3.capture2e(*compiler,'-I','lib','--strict-require',*flags,'benchmark/call_cost_worker.rb','-o',worker)
  File.write('build/benchmark/m2-worker-build.log',log)
  abort log unless status.success?
end
expected = {
  'array_scan' => (rounds * (256 * seed + 32640)) & 0xffffffff,
  'copy_fill' => rounds.times.sum { |i| (seed + i) & 255 } & 0xffffffff,
  'global_update' => (seed + rounds * 1664525) & 0xffffffff,
  'segment_init' => (seed + rounds.times.sum { |i| '0123456789abcdef'.getbyte(i & 15) }) & 0xffffffff
}
runners = {'CRuby' => [RbConfig.ruby,'--disable-yjit','-Ilib','benchmark/call_cost_worker.rb'], 'Spinel' => [worker]}
rows = []
expected.each do |name, checksum|
  (runs + warmups).times do |run|
    order = run.even? ? runners.to_a : runners.to_a.reverse
    order.each do |runtime, command|
      output, error, status = Open3.capture3(*command,binary,name,rounds.to_s,seed.to_s,'inline')
      abort "#{runtime}/#{name}: #{error}" unless status.success?
      loading, translation, execution, actual = output.strip.split(',')
      abort "checksum mismatch: #{runtime}/#{name}: #{actual} != #{checksum}" unless Integer(actual) == checksum
      if run >= warmups
        rows << {runtime: runtime, export: name, load: Float(loading) + Float(translation), execution: Float(execution), checksum: Integer(actual)}
      end
    end
  end
end
spinel_version, status = Open3.capture2e(*compiler,'--version')
abort spinel_version unless status.success?
puts JSON.pretty_generate({ruby: RUBY_DESCRIPTION, spinel: spinel_version.strip, compiler_flags: flags,
  runs: runs, warmups: warmups, rounds: rounds, seed: seed, disabled: ['inline'], samples: rows})
