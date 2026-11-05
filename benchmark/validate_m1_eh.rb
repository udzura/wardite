# frozen_string_literal: true

# Optional reference-engine validation; ordinary tests require only wasm-tools.
# Usage: bundle exec ruby -Ilib benchmark/validate_m1_eh.rb
require 'wardite'
require 'open3'
require 'tmpdir'
require_relative '../test/support/efflorescence_m1_cases'

puts Open3.capture2('wasmtime', '--version').first.strip
puts Open3.capture2('wasm-tools', '--version').first.strip
count = 0
Dir.mktmpdir('wardite-m1-reference') do |dir|
  EfflorescenceM1Cases::EH_CASES.each_with_index do |(name, wat, calls), i|
    source = File.join(dir, "#{i}.wat")
    binary = File.join(dir, "#{i}.wasm")
    File.write(source, wat)
    [['wasm-tools', 'parse', source, '-o', binary], ['wasm-tools', 'validate', binary]].each do |command|
      output, status = Open3.capture2e(*command)
      abort output unless status.success?
    end
    vm = File.open(binary, 'rb') { |file| Wardite::BinaryLoader.load_from_buffer(file, engine: :efflorescence, enable_wasi: false).runtime }
    calls.each do |export, args, expected|
      output, error, status = Open3.capture3('wasmtime', 'run', '-W', 'exceptions=y', '--invoke', export, binary, *args.map(&:to_s))
      abort "#{name}/#{export}: #{error}" unless status.success?
      reference = Integer(output.strip) & 0xffffffff
      actual = vm.call_unboxed(export, args)
      abort "#{name}: expected #{expected}, Wasmtime #{reference}, MIR #{actual}" unless reference == expected && actual == expected
      count += 1
    end
    puts "PASS #{name}"
  end
end
puts "#{count} EH calls agree with fixed expectations and Wasmtime (-W exceptions=y)."
