# frozen_string_literal: true

# Compare identical call_cost_worker executables built against two revisions.
# Usage: bundle exec ruby benchmark/measure_m1.rb BEFORE_WORKER AFTER_WORKER
# Workers: spinel -I lib --strict-require -O2 benchmark/call_cost_worker.rb -o PATH
require 'open3'
require 'json'
require 'tmpdir'

workers = ARGV
abort 'Pass before and after worker executable paths' unless workers.size == 2
runs = Integer(ENV.fetch('RUNS', '5'))
warmups = Integer(ENV.fetch('WARMUPS', '2'))
rounds = Integer(ENV.fetch('ROUNDS', '100000'))
mix = 123
rounds.times do
  mix ^= mix >> 13
  mix = (mix * 1664525 + 1013904223) & 0xffffffff
  mix = (mix ^ (mix << 7)) & 0xffffffff
end
expected = {'inline_mix' => mix, 'call_mix' => mix, 'empty_loop' => 123,
            'call_zero' => (123 + rounds * 7) & 0xffffffff, 'call_one' => 123,
            'call_two' => (123 + rounds) & 0xffffffff,
            'call_three' => (123 + rounds * 3) & 0xffffffff,
            'call_four' => (123 + rounds * 6) & 0xffffffff}
rows = []
Dir.mktmpdir('wardite-m1-bench') do |dir|
  {'i32_mix' => %w[inline_mix call_mix], 'i32_call_arities' => %w[empty_loop call_zero call_one call_two call_three call_four]}.each do |file, names|
    wasm = File.join(dir, "#{file}.wasm")
    abort 'parse failed' unless system('wasm-tools', 'parse', "benchmark/#{file}.wat", '-o', wasm)
    names.each do |name|
      (warmups + runs).times do |run|
        # Alternate order to reduce systematic drift across the comparison.
        order = run.even? ? [0, 1] : [1, 0]
        values = []
        order.each do |i|
          output, error, status = Open3.capture3(workers[i], wasm, name, rounds.to_s, '123', 'inline')
          abort error unless status.success?
          loading, translation, execution, checksum = output.strip.split(',')
          values[i] = Integer(checksum)
          if run >= warmups
            rows << {revision: i == 0 ? 'before' : 'after', export: name,
                     load: Float(loading) + Float(translation), execution: Float(execution), checksum: Integer(checksum)}
          end
        end
        abort "checksum mismatch for #{name}" unless values[0] == values[1] && values[0] == expected.fetch(name)
      end
    end
  end
end
puts JSON.pretty_generate({workers: workers, runs: runs, warmups: warmups, rounds: rounds, seed: 123, disabled: ['inline'], samples: rows})
