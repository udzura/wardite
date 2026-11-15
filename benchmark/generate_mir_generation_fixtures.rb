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
