# frozen_string_literal: true

require "fileutils"
directory = File.expand_path(ARGV.fetch(0))
FileUtils.mkdir_p(directory)
[256, 512, 1024, 2048, 4096, 8192].each do |size|
  path = File.join(directory, "i32-chain-#{size}")
  File.write("#{path}.wat", <<~WAT)
    (module
      (func (export "run") (param i32) (result i32)
        #{'local.get 0 i32.const 1 i32.add local.set 0 ' * size}
        local.get 0))
  WAT
  abort "wasm-tools failed" unless system("wasm-tools", "parse", "#{path}.wat", "-o", "#{path}.wasm")
end

{
  "i32-many-blocks" => <<~WAT,
    (module
      (func (export "run") (param i32) (result i32)
        #{'block local.get 0 i32.const 1 i32.add local.set 0 br 0 end ' * 2048}
        local.get 0))
  WAT
  "i32-root-overwrites" => <<~WAT,
    (module
      (func (export "run") (param i32) (result i32) (local i32 i32)
        #{'local.get 0 local.set 1 local.get 1 local.set 2
           local.get 0 i32.const 1 i32.add local.set 0
           local.get 1 local.get 2 i32.add local.set 1 ' * 2048}
        local.get 0 local.get 1 i32.xor))
  WAT
  "i32-copy-chain" => <<~WAT,
    (module
      (func (export "run") (param i32) (result i32) (local #{'i32 ' * 2048})
        #{(1..2048).map { |index| "local.get #{index - 1} local.set #{index}" }.join(" ")}
        local.get 2048))
  WAT
  "i32-wide-call" => <<~WAT,
    (module
      (func $wide (param #{'i32 ' * 32}) (result i32)
        local.get 0 #{(1...32).map { |index| "local.get #{index} i32.add" }.join(" ")})
      (func (export "run") (param i32) (result i32) (local i32)
        #{("local.get 0 local.set 1 #{'local.get 1 ' * 31} i32.const 17 call $wide local.set 0 ") * 256}
        local.get 0))
  WAT
  "i32-wide-frame" => <<~WAT
    (module
      (func (export "run") (param i32) (result i32) (local #{'i32 ' * 32768})
        local.get 0 local.set 32768 local.get 32768))
  WAT
}.each do |name, wat|
  path = File.join(directory, name)
  File.write("#{path}.wat", wat)
  abort "wasm-tools failed" unless system("wasm-tools", "parse", "#{path}.wat", "-o", "#{path}.wasm")
end

# Scale exception-flow validation while keeping each function small.
path = File.join(directory, "eh-512")
File.open("#{path}.wat", "w") do |wat|
  wat.puts "(module (tag $e (param i32)) (func $raise i32.const 42 throw $e)"
  512.times do |index|
    export = index.zero? ? '(export "run")' : ""
    wat.puts <<~WAT
      (func #{export} (result i32)
        block $done (result i32)
          #{'try_table (catch $e $done) call $raise end ' * 32}
          i32.const 0
        end)
    WAT
  end
  wat.puts ")"
end
abort "wasm-tools failed" unless system("wasm-tools", "parse", "#{path}.wat", "-o", "#{path}.wasm")

# Many static CALL sites to one eligible leaf exceed the per-caller budget.
path = File.join(directory, "inline-dense")
File.write("#{path}.wat", <<~WAT)
  (module
    (func $leaf (param i32) (result i32) local.get 0 i32.const 1 i32.add)
    (func (export "run") (param i32) (result i32)
      #{'local.get 0 call $leaf local.set 0 ' * 256}
      local.get 0))
WAT
abort "wasm-tools failed" unless system("wasm-tools", "parse", "#{path}.wat", "-o", "#{path}.wasm")
