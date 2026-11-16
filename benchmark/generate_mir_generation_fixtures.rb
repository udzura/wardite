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
