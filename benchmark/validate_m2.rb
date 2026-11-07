# frozen_string_literal: true

# Compare results and an order-sensitive checksum of every memory byte, page
# count and i32 global against Wasmtime. Unit/native tests additionally compare
# full snapshots and fixed expected mutations, including after traps.
require 'wardite'
require 'open3'
require 'tmpdir'
require_relative '../test/support/efflorescence_m2_cases'

C = EfflorescenceM2Cases
MASK = 0xffffffff

def checked(command)
  output, status = Open3.capture2e(*command)
  abort output unless status.success?
  output
end

def digest_function(memory, globals)
  scan = memory ? <<~WAT : ''
    block $done loop $scan
      local.get $p memory.size i32.const 16 i32.shl i32.ge_u br_if $done
      local.get $h local.get $p i32.load8_u i32.xor i32.const 16777619 i32.mul local.set $h
      local.get $p i32.const 1 i32.add local.set $p br $scan
    end end
  WAT
  pages = memory ? 'memory.size' : 'i32.const 0'
  global_hash = globals.map { |i| "i32.const 16777619 i32.mul global.get #{i} i32.xor" }.join(' ')
  "(func $__m2_digest (result i32) (local $h i32) (local $p i32) i32.const -2128831035 local.set $h #{scan} local.get $h #{pages} i32.xor #{global_hash})"
end

def state_hash(instance)
  hash = 2166136261
  memory = instance.store.memories[0]
  memory&.data&.each_byte { |byte| hash = ((hash ^ byte) * 16777619) & MASK }
  hash ^= memory ? memory.current : 0
  instance.store.globals.each do |global|
    hash = (((hash * 16777619) & MASK) ^ global.value.value) if global.type == :i32
  end
  hash & MASK
end

memory_wat = C::MEMORY_WAT.rstrip[0...-1] + '(data (i32.const 1) "\80\ff\01\80"))'
cases = [
  [C::GLOBAL_WAT, 'get', [], 7], [C::GLOBAL_WAT, 'snapshot', [], MASK],
  [C::GLOBAL_WAT, 'direct', [40], 7], [C::GLOBAL_WAT, 'recursive', [3], 24],
  [memory_wat, 'load', [1], 0x8001ff80], [memory_wat, 'load8_s', [1], 0xffffff80], [memory_wat, 'load8_u', [1], 128],
  [memory_wat, 'load16_s', [1], 0xffffff80], [memory_wat, 'load16_u', [1], 0xff80], [memory_wat, 'offset', [1], 128],
  [memory_wat, 'store', [65532,0x89abcdef], nil], [memory_wat, 'store8', [65535,0x89abcdef], nil],
  [memory_wat, 'store16', [65534,0x89abcdef], nil], [memory_wat, 'load', [65533], :trap],
  [memory_wat, 'load8_u', [-1], :trap], [memory_wat, 'overflow', [1], :trap],
  [memory_wat, 'store_overflow', [1], :trap],
  [C::GROW_WAT, 'grow', [0], 1], [C::GROW_WAT, 'grow', [1], 1], [C::GROW_WAT, 'grow', [2], 1],
  [C::GROW_WAT, 'grow', [3], MASK], [C::GROW_WAT, 'grow', [MASK], MASK], [C::GROW_WAT, 'callee', [], 53],
  [C::BULK_WAT, 'init', [20,0,9], nil], [C::BULK_WAT, 'init', [65527,0,9], nil],
  [C::BULK_WAT, 'init', [65536,9,0], nil], [C::BULK_WAT, 'init', [0,8,2], :trap], [C::BULK_WAT, 'active', [0,0,1], :trap],
  [C::BULK_WAT, 'active', [65536,0,0], nil], [C::BULK_WAT, 'empty', [65536,0,0], nil],
  [C::BULK_WAT, 'copy', [2,0,4], nil], [C::BULK_WAT, 'copy', [0,2,4], nil],
  [C::BULK_WAT, 'copy', [0,0,65536], nil], [C::BULK_WAT, 'copy', [65536,65536,0], nil],
  [C::BULK_WAT, 'copy', [65535,0,2], :trap], [C::BULK_WAT, 'copy', [0,65535,2], :trap],
  [C::BULK_WAT, 'fill', [1,256,4], nil], [C::BULK_WAT, 'fill', [65535,MASK,1], nil],
  [C::BULK_WAT, 'fill', [65536,42,0], nil], [C::BULK_WAT, 'fill', [65537,42,0], :trap],
  [C::INTEGRATION_WAT, 'get', [], 5], [C::INTEGRATION_WAT, 'load', [0], 11],
  [C::INTEGRATION_WAT, 'caught', [], 51], [C::INTEGRATION_WAT, 'snapshot', [], 0xffffffd8],
  [C::INTEGRATION_WAT, 'reuse', [], 0], [C::INTEGRATION_WAT, 'pure', [], 42],
  [C::INTEGRATION_WAT, 'trap', [], :trap], [C::INTEGRATION_WAT, 'uncaught', [], :exception]
]
puts checked(['wasmtime','--version']).strip
puts checked(['wasm-tools','--version']).strip
normal = traps = exceptions = 0
Dir.mktmpdir('wardite-m2-reference') do |dir|
  cases.each_with_index do |(wat, name, args, expected), i|
    source = File.join(dir, 'input.wat')
    binary = File.join(dir, 'input.wasm')
    File.write(source, wat)
    checked(['wasm-tools','parse',source,'-o',binary])
    checked(['wasm-tools','validate',binary])
    instance = File.open(binary, 'rb') { |file| Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false, engine: :efflorescence) }
    target = instance.export_section.exports.fetch(name)
    globals = instance.store.globals.each_index.select { |index| instance.store.globals[index].type == :i32 }
    arguments = args.map { |n| "i32.const #{(n & MASK) >= 2**31 ? (n & MASK) - 2**32 : (n & MASK)}" }.join(' ')
    function = instance.store.funcs.fetch(target.index)
    drop = function.retsig.empty? ? '' : 'drop'
    wrapper = "(func (export \"__m2_probe\") (result i32) #{arguments} call #{target.index} #{drop} call $__m2_digest)"
    probe_wat = wat.rstrip[0...-1] + digest_function(!instance.store.memories.empty?, globals) + wrapper + ')'
    File.write(source, probe_wat)
    checked(['wasm-tools','parse',source,'-o',binary])
    checked(['wasm-tools','validate',binary])
    output, error, status = Open3.capture3('wasmtime','run','-W','exceptions=y','--invoke','__m2_probe',binary)
    if expected == :trap
      begin
        instance.runtime.call_unboxed(name,args)
        abort "missing Wardite trap: #{name}"
      rescue Wardite::EvalError
      end
      abort "missing Wasmtime memory trap: #{error}" unless !status.success? && error.include?('out of bounds memory access')
      traps += 1
    elsif expected == :exception
      begin
        instance.runtime.call_unboxed(name,args)
        abort 'missing Wardite exception'
      rescue Wardite::UncaughtWasmException => exception
        abort 'lost exception payload' unless exception.payload == [17]
      end
      abort "missing Wasmtime exception: #{error}" unless !status.success? && error.match?(/exception/i)
      exceptions += 1
    else
      actual = instance.runtime.call_unboxed(name,args)
      abort "bad fixed result #{name}: #{actual} != #{expected}" unless actual == expected
      abort "Wasmtime failed: #{error}" unless status.success?
      hash = state_hash(instance)
      abort "Store state differs: #{name} #{args}: #{output.strip} != #{hash}" unless (Integer(output.strip) & MASK) == hash
      normal += 1
    end
    puts "PASS #{i + 1}: #{name} #{args}"
  end
end
puts "#{normal} full-memory/page/global checksum comparisons, #{traps} memory traps, #{exceptions} uncaught exception agree with Wasmtime."
