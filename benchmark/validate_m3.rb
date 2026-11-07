# frozen_string_literal: true

# Usage: ruby -Ilib benchmark/validate_m3.rb
require "wardite"
require "open3"
require "tmpdir"
require_relative "../test/support/efflorescence_m3_cases"

puts Open3.capture2("wasmtime", "--version").first.strip
puts Open3.capture2("wasm-tools", "--version").first.strip

Dir.mktmpdir("wardite-m3-reference") do |dir|
  wat = File.join(dir, "m3.wat")
  wasm = File.join(dir, "m3.wasm")
  File.write(wat, EfflorescenceM3Cases::REFERENCE_WAT)
  [["wasm-tools", "parse", wat, "-o", wasm], ["wasm-tools", "validate", wasm]].each do |command|
    output, status = Open3.capture2e(*command)
    abort output unless status.success?
  end
  vm = Wardite.new(path: wasm, enable_wasi: false, engine: :efflorescence).runtime

  [[0, 14], [1, 105]].each do |selector, expected|
    out, err, status = Open3.capture3("wasmtime", "run", "-W", "exceptions=y", "--invoke", "run", wasm, selector.to_s, "5")
    abort err unless status.success?
    actual = vm.call_unboxed(:run, [selector, 5])
    abort "selector #{selector}: expected #{expected}, Wasmtime #{out.strip}, MIR #{actual}" unless
      actual == expected && Integer(out.strip) == expected
  end

  [[2, "indirect call type mismatch", "function type mismatch"],
   [3, "uninitialized element", "null reference"],
   [4, "out of bounds table access", "table index out of bounds"],
   [-1, "out of bounds table access", "table index out of bounds"]].each do |selector, reference, expected|
    _, err, status = Open3.capture3("wasmtime", "run", "-W", "exceptions=y", "--invoke", "run", wasm, selector.to_s, "5")
    abort "selector #{selector}: expected Wasmtime #{reference}\n#{err}" if status.success? || !err.include?(reference)
    begin
      vm.call_unboxed(:run, [selector, 5])
      abort "selector #{selector}: expected MIR #{expected}"
    rescue Wardite::EvalError => error
      abort error.message unless error.message.include?(expected)
    end
  end
end
puts "Six indirect calls agree with Wasmtime (-W exceptions=y), including a caught throw and four traps."
