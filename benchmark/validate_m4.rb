# frozen_string_literal: true

# Usage: bundle exec ruby -Ilib benchmark/validate_m4.rb
require "wardite"
require "open3"
require "tmpdir"
require_relative "../test/support/efflorescence_m4_cases"
require_relative "../test/support/efflorescence_m4_alu_cases"

include EfflorescenceM4Cases
include EfflorescenceM4ALUCases

def capture!(*command)
  output, error, status = Open3.capture3(*command)
  abort "#{command.inspect}\n#{output}#{error}" unless status.success?
  output.strip
end

def compare(dir, name, wat, cases)
  source = File.join(dir, "#{name}.wat")
  binary = File.join(dir, "#{name}.wasm")
  File.write(source, wat)
  capture!("wasm-tools", "parse", source, "-o", binary)
  capture!("wasm-tools", "validate", binary)
  vm = Wardite.new(path: binary, engine: :efflorescence, enable_wasi: false).runtime
  cases.each do |export, *args, expected|
    reference_args = export.start_with?("i64.extend_i32_") ? args.map { |arg| signed_field(arg, 32) } : args
    command = ["wasmtime", "run", "-W", "exceptions=y", "--invoke", export, "--", binary, *reference_args.map(&:to_s)]
    if expected.is_a?(Integer)
      result = Integer(capture!(*command))
      result %= 2**32 if expected > 2**31 - 1 && result.negative?
      actual = vm.call_unboxed(export, args)
      abort "#{export} #{args}: #{expected} expected, #{result} Wasmtime, #{actual} Efflorescence" unless result == expected && actual == expected
    else
      _, error, status = Open3.capture3(*command)
      trap = {
        "zero" => "integer divide by zero",
        "overflow" => "integer overflow",
        "type" => "indirect call type mismatch",
        "bounds" => "out of bounds memory access"
      }.fetch(expected)
      abort "#{command.inspect}\n#{error}" if status.success? || !error.include?(trap)

      begin
        vm.call_unboxed(export, args)
      rescue Wardite::IntegerOverflow
        raise unless expected == "overflow"
        next
      rescue Wardite::EvalError => failure
        wardite_trap = expected == "type" ? "call_indirect function type mismatch" : trap
        raise unless failure.message.include?(wardite_trap)
        next
      end
      abort "#{export} #{args}: Efflorescence did not trap"
    end
  end
  puts "#{name}: #{cases.size} calls agree"
end

puts capture!("wasmtime", "--version")
puts capture!("wasm-tools", "--version")
Dir.mktmpdir("wardite-m4-reference") do |dir|
  functions, rows = alu_cases
  # Exercise all 35 ALU/convert exports, keeping subprocess count bounded.
  selected = rows.group_by(&:first).values.flat_map do |cases|
    numeric, traps = cases.partition { |row| row.last.is_a?(Integer) }
    [numeric.first, numeric.fetch(numeric.size / 2), numeric.last] + traps.uniq(&:last)
  end
  compare(dir, "alu", "(module #{functions})", selected)
  compare(dir, "control", CONTROL_WAT, [
    ["recursive", 3, MIN, MIN], ["reset", MIN, 0],
    ["branch", 0, MIN], ["branch", 1, 1], ["select", MIN, 1, MIN]
  ])
  compare(dir, "store_and_eh", STORE_EH_WAT, [
    *STORE_EH_ROWS.take(7), ["offset_trap", -1, "bounds"], ["get", MIN], ["eh", MIN, MIN], ["eh", -1, -1]
  ])

  indirect = <<~WAT
    (module
      (type $callee (func (param i32 i64) (result i64)))
      (type $site (func (param i32 i64) (result i64)))
      (table 2 funcref)
      (elem (i32.const 0) func $f $wrong)
      (func $f (type $callee) local.get 1 local.get 0 i64.extend_i32_u i64.xor)
      (func $wrong (param i64 i64) (result i64) unreachable)
      (func (export "indirect") (param i32 i64) (result i64)
        i32.const 1 local.get 1 local.get 0 call_indirect (type $site))
      (func (export "legacy_wrapper") (param i32) (result i64)
        local.get 0 i64.const -9223372036854775808 call $f))
  WAT
  compare(dir, "indirect", indirect, [["indirect", 0, MIN, MIN + 1], ["indirect", 1, MIN, "type"],
    ["legacy_wrapper", 1, MIN + 1]])
  stack = Wardite.new(path: File.join(dir, "indirect.wasm"), enable_wasi: false).runtime
  abort "legacy wrapper mismatch" unless stack.call("legacy_wrapper", [1]).value_s == MIN + 1
end
