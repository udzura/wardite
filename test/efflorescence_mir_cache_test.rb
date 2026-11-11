# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "rbconfig"
require_relative "support/efflorescence_helper"

class EfflorescenceMIRCacheTest < Test::Unit::TestCase
  include EfflorescenceHelper

  STATE_WAT = <<~WAT
    (module
      (type $answer (func (result i32)))
      (import "env" "answer" (func $answer (type $answer)))
      (memory 1)
      (data (i32.const 0) "A")
      (data $passive "B")
      (global $g (mut i32) (i32.const 0))
      (table 1 funcref)
      (elem (i32.const 0) func $answer)
      (func $init
        call $answer global.set $g
        i32.const 1 i32.const 0 i32.const 1 memory.init $passive)
      (start $init)
      (func (export "read") (result i32)
        i32.const 0 i32.load8_u i32.const 1 i32.load8_u i32.add
        global.get $g i32.add)
      (func (export "run") (result i32)
        i32.const 0 i32.const 90 i32.const 2 memory.fill
        i32.const 0 global.set $g
        i32.const 0 call_indirect (type $answer))
      (func (export "trap") unreachable))
  WAT

  def setup
    @directory = Dir.mktmpdir("wardite-mir-cache-test")
    @cache = File.join(@directory, "cache")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  test "start effects, memory, globals, and host bindings are fresh after a hit" do
    wasm = compile_efflorescence_wat(STATE_WAT)
    calls = []
    make_imports = ->(answer) do
      {env: {answer: ->(_store, _args) { calls << answer; answer }}}
    end
    baseline = load_bytes(wasm, cache: nil, import_object: make_imports.call(3))
    first = load_bytes(wasm, import_object: make_imports.call(3))
    assert_false first.mir_cache_hit
    assert_equal baseline.call_unboxed(:read, []), first.call_unboxed(:read, [])
    assert_equal 3, first.call_unboxed(:run, [])
    assert_equal 180, first.call_unboxed(:read, [])

    hit = load_bytes(wasm, import_object: make_imports.call(7))
    assert_true hit.mir_cache_hit
    assert_equal 138, hit.call_unboxed(:read, [])
    assert_equal 7, hit.call_unboxed(:run, [])
    assert_raise(Wardite::Unreachable) { baseline.call_unboxed(:trap, []) }
    assert_raise(Wardite::Unreachable) { hit.call_unboxed(:trap, []) }
    assert_equal [3, 3, 3, 7, 7], calls

    assert_raise(NameError) { load_bytes(wasm) }
    assert_equal baseline.dump_mir, hit.dump_mir
    assert_equal 7, hit.call_unboxed(:run, [])
  end

  test "round trips signed i64, f32 and f64 bits, direct calls, and catch_ref metadata" do
    fixture = File.join(__dir__, "fixtures/efflorescence/m5_store_eh.wat")
    wasm = compile_efflorescence_wat(File.read(fixture))
    miss = load_bytes(wasm)
    hit = load_bytes(wasm)

    assert_false miss.mir_cache_hit
    assert_true hit.mir_cache_hit
    assert_equal miss.ir.functions.map(&:bytecode), hit.ir.functions.map(&:bytecode)
    assert_equal miss.ir.functions.map(&:initial_registers), hit.ir.functions.map(&:initial_registers)
    [miss, hit].each do |vm|
      assert_equal 1, vm.call_unboxed(:repeat_eh, [])
      assert_raise(Wardite::EvalError) { vm.call_unboxed(:trap, []) }
      error = assert_raise(Wardite::UncaughtWasmException) { vm.call_unboxed(:raise, []) }
      assert_equal [0xffffffff, 0xff800123, -7, -(1 << 63)], error.exception_value.payload_bits
    end
  end

  test "the key covers Wasm and normalized optimization settings" do
    wasm = compile_efflorescence_wat('(module (func (export "value") (result i32) i32.const 1))')
    changed = compile_efflorescence_wat('(module (func (export "value") (result i32) i32.const 2))')
    assert_false load_bytes(wasm, disabled_optimizations: [:copy, :frames]).mir_cache_hit
    assert_true load_bytes(wasm, disabled_optimizations: [:frames, :copy, :frames]).mir_cache_hit
    assert_false load_bytes(wasm).mir_cache_hit
    assert_false load_bytes(wasm, disabled_optimizations: [:all]).mir_cache_hit
    assert_true load_bytes(wasm, disabled_optimizations: Wardite::Efflorescence::Configuration::FEATURES).mir_cache_hit
    vm = load_bytes(changed)
    assert_false vm.mir_cache_hit
    assert_equal 2, vm.call_unboxed(:value, [])
    assert_equal 4, cache_files.size
  end

  test "changing the code compatibility version selects a different cache file" do
    wasm = File.binread(add_wasm)
    assert_false load_bytes(wasm).mir_cache_hit
    worker = <<~'RUBY_WORKER'
      require "wardite"
      require "wardite/efflorescence/mir_cache"
      cache = Wardite::Efflorescence::MIRCache
      version = cache.send(:remove_const, :CODE_VERSION)
      cache.const_set(:CODE_VERSION, version + 1)
      wasm, dir = ARGV
      vm = Wardite.new(path: wasm, engine: :efflorescence, mir_cache: dir).runtime
      abort "unexpected cache hit" if vm.mir_cache_hit
      puts vm.call_unboxed(:add, [20, 22])
    RUBY_WORKER
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", worker, add_wasm, @cache)
    assert_true status.success?, stderr
    assert_equal "42\n", stdout
    assert_equal 2, cache_files.size
    assert_true load_bytes(wasm).mir_cache_hit
  end

  test "linking uses the optimization settings captured in the cache key" do
    wasm = compile_efflorescence_wat(<<~WAT)
      (module
        (import "env" "unused" (func))
        (func (export "value") (param i32) (result i32)
          local.get 0 i32.const 1 i32.add))
    WAT
    options = []
    host = Wardite::HashModule.new(unused: ->(_store, _args) {})
    imports = Hash.new do
      options << :immediate
      host
    end
    miss = load_bytes(wasm, import_object: imports, disabled_optimizations: options)
    assert_equal [:immediate], options
    hit = load_bytes(wasm, import_object: {env: host})
    assert_true hit.mir_cache_hit
    assert_equal miss.ir.functions.first.bytecode, hit.ir.functions.first.bytecode
    assert_include hit.ir.functions.first.bytecode.each_slice(4).map(&:first),
      Wardite::Efflorescence::Opcode::I32_ADD_IMM
    assert_equal 42, hit.call_unboxed(:value, [41])
  end

  test "format mismatch, truncation, invalid counts, opcodes, register and branch indices fall back" do
    wasm = compile_efflorescence_wat(<<~WAT)
      (module (func (export "value") (param i32) (result i32)
        block local.get 0 br_if 0 unreachable end local.get 0))
    WAT
    baseline = load_bytes(wasm)
    file = cache_files.fetch(0)
    original = File.binread(file)
    header_size = 48
    payload_offset = header_size + 32
    layout_offset = payload_offset + 4
    function_count = layout_offset + original.unpack1("l<", offset: payload_offset)
    type_vector = function_count + 8 # function count and flags
    initial_vector = type_vector + 4 + original.unpack1("l<", offset: type_vector)
    constant_vector = initial_vector + 4 + 8 * original.unpack1("l<", offset: initial_vector)
    code_vector = constant_vector + 4 + 4 * original.unpack1("l<", offset: constant_vector)
    branch = baseline.ir.functions.fetch(0).bytecode.each_slice(4).find_index do |opcode, *_|
      opcode == Wardite::Efflorescence::Opcode::BR_IF
    end
    branch_offset = code_vector + 4 + branch * 32

    mutations = [
      original.byteslice(0...-1),
      patched(original, 8, "l<", 999), # format version
      patched(original, 12, "l<", 999), # code version
      patched(original, payload_offset, "C", original.getbyte(payload_offset) ^ 1), # checksum
    ]
    [
      [layout_offset, "C", original.getbyte(layout_offset) ^ 1], # module layout
      [function_count, "l<", 0x7fffffff],
      [code_vector, "l<", 3], # code width
      [branch_offset, "q<", 999], # opcode
      [branch_offset + 8, "q<", -1], # register index
      [branch_offset + 16, "q<", 1], # unaligned target
      [branch_offset + 16, "q<", 0x7ffffffc], # out-of-range target
    ].each do |offset, format, value|
      corrupt = patched(original, offset, format, value)
      corrupt[header_size, 32] = Digest::SHA256.digest(corrupt.byteslice(payload_offset..))
      mutations << corrupt
    end

    mutations.each do |corrupt|
      File.binwrite(file, corrupt)
      rebuilt = load_bytes(wasm)
      assert_false rebuilt.mir_cache_hit
      assert_equal 42, rebuilt.call_unboxed(:value, [42])
      assert_equal original, File.binread(file)
    end
    assert_true load_bytes(wasm).mir_cache_hit
  end

  test "cache I/O failure leaves a successful build executable" do
    File.write(@cache, "not a directory")
    vm = load_bytes(File.binread(add_wasm))
    assert_false vm.mir_cache_hit
    assert_equal 42, vm.call_unboxed(:add, [20, 22])
    assert_equal "not a directory", File.read(@cache)
  end

  test "a read-only cache directory falls back to execution" do
    Dir.mkdir(@cache, 0o500)
    omit "effective user can write to read-only directories" if File.writable?(@cache)
    vm = load_bytes(File.binread(add_wasm))
    assert_false vm.mir_cache_hit
    assert_equal 42, vm.call_unboxed(:add, [20, 22])
    assert_empty Dir.children(@cache)
  ensure
    File.chmod(0o700, @cache) if File.directory?(@cache)
  end

  test "CLI reuses a cache across processes and bypasses it for dump and profile" do
    assert_cli("MIR2 cache miss")
    assert_cli("MIR2 cache hit")
    assert_cli("Semantic MIR", "--mir-dump", bypass: true)
    assert_cli("dispatches=", "--mir-profile", bypass: true)
    assert_cli("MIR2 cache hit")
    assert_equal 1, cache_files.size

    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "exe/wardite", "--mir-cache", @cache, add_wasm)
    assert_false status.success?
    assert_include stderr, "require --new-engine"
  end

  test "two processes can publish the same cache entry concurrently" do
    worker = <<~'RUBY_WORKER'
      require "wardite"
      require "wardite/efflorescence/mir_cache"
      Wardite::Efflorescence::MIRCache.prepend(Module.new do
        def write(*)
          puts "ready"
          $stdout.flush
          abort "write cancelled" unless $stdin.gets
          super
        end
      end)
      wasm, cache = ARGV
      vm = Wardite.new(path: wasm, engine: :efflorescence, mir_cache: cache).runtime
      abort "unexpected cache hit" if vm.mir_cache_hit
      puts vm.call_unboxed(:add, [20, 22])
    RUBY_WORKER
    command = [RbConfig.ruby, "-Ilib", "-e", worker, add_wasm, @cache]
    Open3.popen3(*command) do |first_in, first_out, first_err, first_wait|
      Open3.popen3(*command) do |second_in, second_out, second_err, second_wait|
        [first_out, second_out].each do |output|
          assert_not_nil IO.select([output], nil, nil, 10), "writer did not reach the gate"
          assert_equal "ready\n", output.gets
        end
        [first_in, second_in].each { |input| input.puts("write"); input.close }
        assert_equal "42\n", first_out.read
        assert_equal "42\n", second_out.read
        assert_true first_wait.value.success?, first_err.read
        assert_true second_wait.value.success?, second_err.read
      end
    end
    assert_equal cache_files.map { |path| File.basename(path) }, Dir.children(@cache)
    assert_equal 1, cache_files.size
    assert_cli("MIR2 cache hit")
  end

  private

  def add_wasm
    File.join(__dir__, "add.wasm")
  end

  def cache_files
    Dir.glob(File.join(@cache, "*.mir2"))
  end

  def load_bytes(wasm, cache: @cache, **options)
    Wardite::BinaryLoader.load_from_buffer(StringIO.new(wasm), enable_wasi: false,
      engine: :efflorescence, mir_cache: cache, **options).runtime
  end

  def patched(bytes, offset, format, value)
    word = [value].pack(format)
    result = bytes.dup
    result[offset, word.bytesize] = word
    result
  end

  def assert_cli(message, *options, bypass: false)
    stdout, stderr, status = Open3.capture3({"WARITE_TRACE" => "1"}, RbConfig.ruby, "-Ilib", "exe/wardite",
      "--new-engine", "--mir-cache", @cache, "--no-wasi", "--invoke", "add", *options, "--", add_wasm, "20", "22")
    assert_true status.success?, stderr
    assert_empty stdout
    assert_include stderr, "return value: I32(42)"
    assert_include stderr, message
    assert_not_include stderr, "MIR2 cache" if bypass
  end
end
