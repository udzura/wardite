# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "rbconfig"
require_relative "support/efflorescence_helper"

class EfflorescenceMIRCacheTest < Test::Unit::TestCase
  include EfflorescenceHelper
  CACHE_HEADER_SIZE = 48
  PAYLOAD_OFFSET = 120

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
    hit = load_bytes(wasm, mir_cache_eager: true)

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

  test "a hit decodes function bodies only when they are inspected" do
    wasm = compile_efflorescence_wat(<<~WAT)
      (module
        (type $pair (func (result i32 i32)))
        (func (export "value") (result i32)
          block (type $pair) i32.const 40 i32.const 2 end i32.add)
        (func))
    WAT
    miss = load_bytes(wasm)
    assert_false miss.mir_cache_hit
    decoded = 0
    trace = TracePoint.new(:call) do |event|
      decoded += 1 if event.self.equal?(Wardite::BinaryLoader) && event.method_id == :code_body
    end

    trace.enable do
      buffer = StringIO.new(wasm)
      instance = Wardite::BinaryLoader.load_from_buffer(buffer, enable_wasi: false,
        engine: :efflorescence, mir_cache: @cache)
      buffer.close
      hit = instance.runtime
      assert_true hit.mir_cache_hit
      assert_equal 42, hit.call_unboxed(:value, [])
      assert_equal 0, decoded

      function = instance.store.funcs.fetch(0)
      body = function.body
      assert_equal [:i32, :i32], body.first.fetch(2).first.result_types
      assert_same body, function.body
      assert_equal 1, decoded

      assert_equal miss.dump_mir, hit.dump_mir
      assert_equal 2, decoded
    end
  end

  test "a cache miss checks malformed bodies before Store initialization or import lookup" do
    wasm = compile_efflorescence_wat(<<~WAT)
      (module
        (import "env" "unused" (func))
        (func block (type 8) end))
    WAT
    effects = []
    imports = Hash.new { effects << :import_lookup }
    trace = TracePoint.new(:call) do |event|
      effects << :store if event.defined_class == Wardite::Store && event.method_id == :initialize
    end
    trace.enable do
      error = assert_raise(Wardite::LoadError) { load_bytes(wasm, import_object: imports) }
      assert_equal "invalid block type index 8", error.message
    end
    assert_empty effects
    assert_empty cache_files
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
    assert_equal 42, hit.call_unboxed(:value, [41])
    assert_equal miss.ir.functions.first.bytecode, hit.ir.functions.first.bytecode
    assert_include hit.ir.functions.first.bytecode.each_slice(4).map(&:first),
      Wardite::Efflorescence::Opcode::I32_ADD_IMM
  end

  test "format mismatch, truncation, invalid counts, opcodes, register and branch indices fall back" do
    wasm = compile_efflorescence_wat(<<~WAT)
      (module (func (export "value") (param i32) (result i32)
        block local.get 0 br_if 0 unreachable end local.get 0))
    WAT
    baseline = load_bytes(wasm)
    file = cache_files.fetch(0)
    original = File.binread(file)
    header_size = CACHE_HEADER_SIZE
    payload_offset = PAYLOAD_OFFSET
    layout_offset = payload_offset + 4 + 8 + 4 # count, one table row, and layout length
    function_offset = payload_offset + original.unpack1("l<", offset: payload_offset + 4)
    type_vector = function_offset + 4 # flags
    initial_vector = type_vector + 4 + original.unpack1("l<", offset: type_vector)
    constant_vector = initial_vector + 4 + 8 * original.unpack1("l<", offset: initial_vector)
    code_vector = constant_vector + 4 + 4 * original.unpack1("l<", offset: constant_vector)
    branch = baseline.ir.functions.fetch(0).bytecode.each_slice(4).find_index do |opcode, *_|
      opcode == Wardite::Efflorescence::Opcode::BR_IF
    end
    branch_offset = code_vector + 4 + branch * 32

    mutations = [
      original.byteslice(0...-1),
      patched(original, 0, "C", 0), # magic
      patched(original, 8, "l<", 999), # format version
      patched(original, 12, "l<", 999), # code version
      patched(original, 16, "C", original.getbyte(16) ^ 1), # key
      patched(original, header_size, "Q<", 1), # payload length
      patched(original, payload_offset, "C", original.getbyte(payload_offset) ^ 1), # sampled byte
    ]
    [
      [layout_offset, "C", original.getbyte(layout_offset) ^ 1], # module layout
      [payload_offset, "l<", 0x7fffffff], # function count
      [payload_offset + 4, "l<", -1], # function offset
      [payload_offset + 8, "l<", 0x7fffffff], # function length
      [code_vector, "l<", 3], # code width
      [branch_offset, "q<", 999], # opcode
      [branch_offset + 8, "q<", -1], # register index
      [branch_offset + 16, "q<", 1], # unaligned target
      [branch_offset + 16, "q<", 0x7ffffffc], # out-of-range target
    ].each do |offset, format, value|
      corrupt = patched(original, offset, format, value)
      mutations << update_small_digests(corrupt)
    end

    %i[checksum sha256].product(mutations).each do |mode, corrupt|
      File.binwrite(file, corrupt)
      steps = []
      trace = TracePoint.new(:call) do |event|
        steps << :decode if event.self.equal?(Wardite::BinaryLoader) && event.method_id == :code_body
        steps << :store if event.defined_class == Wardite::Store && event.method_id == :initialize
      end
      rebuilt = trace.enable { load_bytes(wasm, mir_cache_verify: mode, mir_cache_eager: true) }
      assert_equal [:decode, :store], steps
      assert_false rebuilt.mir_cache_hit
      assert_equal 42, rebuilt.call_unboxed(:value, [42])
      assert_equal original, File.binread(file)
    end
    assert_true load_bytes(wasm).mir_cache_hit
  end

  test "lazy restoration follows direct, indirect, host reentry and EH calls" do
    wasm = compile_efflorescence_wat(<<~WAT)
      (module
        (import "env" "reenter" (func $host (result i32)))
        (tag $tag (param i32))
        (table 1 funcref)
        (type $t (func (result i32)))
        (elem (i32.const 0) func $throws)
        (func (export "run") (result i32) call $host)
        (func (export "handler") (result i32)
          (block $caught (result i32)
            (try_table (catch $tag $caught)
              i32.const 0 call_indirect (type $t) drop)
            unreachable))
        (func $throws (result i32) call $value throw $tag)
        (func $value (result i32) i32.const 42)
        (func (export "unused") (result i32) i32.const 99))
    WAT
    disabled = [:all]
    load_bytes(wasm, disabled_optimizations: disabled, import_object: {env: {reenter: ->(*) { 42 }}})
    vm = nil
    host = ->(*) { vm.call_unboxed(:handler, []) }
    vm = load_bytes(wasm, disabled_optimizations: disabled, import_object: {env: {reenter: host}})
    assert_true vm.mir_cache_hit
    assert_equal [true] * 5, vm.ir.functions.map(&:cache_pending)
    assert_equal 42, vm.call_unboxed(:run, [])
    assert_equal [false, false, false, false, true], vm.ir.functions.map(&:cache_pending)
    assert_equal 42, vm.call_unboxed(:run, [])
    vm.optimized_ir
    assert_equal [false] * 5, vm.ir.functions.map(&:cache_pending)
  end

  test "lazy restoration reports a corrupt function only when it is called" do
    wasm = compile_efflorescence_wat(<<~WAT)
      (module
        (func (export "good") (result i32) i32.const 42)
        (func (export "bad") (result i32) i32.const 43))
    WAT
    original_vm = load_bytes(wasm)
    file = cache_files.fetch(0)
    original = File.binread(file)
    offset, length = original.unpack("l<2", offset: PAYLOAD_OFFSET + 12)
    start = PAYLOAD_OFFSET + offset
    code = original.index(original_vm.ir.functions.fetch(1).bytecode.pack("q<*"), start)
    assert_not_nil code
    assert_operator code, :<, start + length
    File.binwrite(file, update_small_digests(patched(original, code, "q<", 999)))

    vm = load_bytes(wasm)
    assert_true vm.mir_cache_hit
    assert_equal 42, vm.call_unboxed(:good, [])
    assert_true vm.ir.functions.fetch(1).cache_pending
    2.times do
      error = assert_raise(Wardite::EvalError) { vm.call_unboxed(:bad, []) }
      assert_include error.message, file
    end
    error = assert_raise(Wardite::EvalError) { vm.dump_mir }
    assert_include error.message, file
    assert_not_equal original, File.binread(file)

    eager = load_bytes(wasm, mir_cache_eager: true)
    assert_false eager.mir_cache_hit
    assert_equal 43, eager.call_unboxed(:bad, [])
    assert_equal original, File.binread(file)
  end

  test "lazy cache loading rejects overlapping or out-of-bounds function records" do
    wasm = compile_efflorescence_wat("(module (func) (func))")
    load_bytes(wasm)
    file = cache_files.fetch(0)
    original = File.binread(file)
    offset = original.unpack1("l<", offset: PAYLOAD_OFFSET + 4)
    [patched(original, PAYLOAD_OFFSET + 12, "l<", offset),
     patched(original, PAYLOAD_OFFSET + 16, "l<", original.bytesize)].each do |corrupt|
      File.binwrite(file, update_small_digests(corrupt))
      assert_false load_bytes(wasm).mir_cache_hit
      assert_equal original, File.binread(file)
    end
  end

  test "both modes share a file and read only the selected digest" do
    wasm = File.binread(add_wasm)
    baseline = load_bytes(wasm, cache: nil).call_unboxed(:add, [20, 22])
    miss = load_bytes(wasm, mir_cache_verify: :sha256)
    assert_false miss.mir_cache_hit
    assert_equal baseline, miss.call_unboxed(:add, [20, 22])
    file = cache_files.fetch(0)
    original = File.binread(file)
    {checksum: CACHE_HEADER_SIZE + 8, sha256: CACHE_HEADER_SIZE + 40}.each do |mode, offset|
      other = mode == :checksum ? :sha256 : :checksum
      File.binwrite(file, patched(original, offset, "C", original.getbyte(offset) ^ 1))
      hit = load_bytes(wasm, mir_cache_verify: other)
      assert_true hit.mir_cache_hit
      assert_equal baseline, hit.call_unboxed(:add, [20, 22])
      rebuilt = load_bytes(wasm, mir_cache_verify: mode)
      assert_false rebuilt.mir_cache_hit
      assert_equal baseline, rebuilt.call_unboxed(:add, [20, 22])
      assert_equal original, File.binread(file)
    end
    assert_equal [file], cache_files
    assert_raise(Wardite::ArgumentError) { load_bytes(wasm, mir_cache_verify: :unknown) }
  end

  test "version 2 files are left aside and rebuilt in version 3" do
    wasm = File.binread(add_wasm)
    load_bytes(wasm)
    current = cache_files.fetch(0)
    indexed = File.binread(current).byteslice(PAYLOAD_OFFSET..)
    count = indexed.unpack1("l<")
    table_end = 4 + count * 8
    body = indexed.unpack1("l<", offset: 4)
    payload = indexed.byteslice(table_end...body) + [count].pack("l<") + indexed.byteslice(body..)
    version = [2, 1].pack("L<2")
    key = Digest::SHA256.digest(version + Digest::SHA256.digest(wasm))
    legacy = File.join(@cache, "#{key.unpack1("H*")}.mir2")
    size = [payload.bytesize].pack("Q<")
    File.binwrite(legacy, "WARDMIR\0".b + version + key + size + Digest::SHA256.digest(size + payload) +
      Digest::SHA256.digest(payload) + payload)
    File.unlink(current)

    assert_false load_bytes(wasm, mir_cache_verify: :sha256).mir_cache_hit
    assert_true load_bytes(wasm).mir_cache_hit
    assert_equal [current, legacy].sort, cache_files.sort
  end

  test "sample checksum hashes length, both edges, and aligned blocks in order" do
    require "wardite/efflorescence/mir_cache"
    cache = Wardite::Efflorescence::MIRCache
    small = "s".b * (128 * 1024)
    length = [small.bytesize].pack("Q<")
    assert_equal Digest::SHA256.digest(length + small), cache.sample_checksum(small, length)

    mib = 1024 * 1024
    edge = 64 * 1024
    block = 4 * 1024
    payload = "a" * edge + "x" * (mib - edge) + "b" * block + "y" * (mib - block) + "c" * 17
    length = [payload.bytesize].pack("Q<")
    expected = length + "a" * edge + "b" * block + "c" * 17 + "y" * (edge - 17) + "c" * 17
    assert_equal Digest::SHA256.digest(expected), cache.sample_checksum(payload, length)
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
    assert_cli("MIR2 cache hit", "--mir-cache-verify", "sha256")
    assert_cli("MIR2 cache hit", "--mir-cache-eager")
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

  def update_small_digests(cache)
    payload = cache.byteslice(PAYLOAD_OFFSET..)
    assert_operator payload.bytesize, :<=, 128 * 1024
    cache[CACHE_HEADER_SIZE + 8, 32] = Digest::SHA256.digest([payload.bytesize].pack("Q<") + payload)
    cache[CACHE_HEADER_SIZE + 40, 32] = Digest::SHA256.digest(payload)
    cache
  end

  def assert_cli(message, *options, bypass: false)
    stdout, stderr, status = Open3.capture3({"WARDITE_TRACE" => "1"}, RbConfig.ruby, "-Ilib", "exe/wardite",
      "--new-engine", "--mir-cache", @cache, "--no-wasi", "--invoke", "add", *options, "--", add_wasm, "20", "22")
    assert_true status.success?, stderr
    assert_empty stdout
    assert_include stderr, "return value: I32(42)"
    assert_include stderr, message
    assert_not_include stderr, "MIR2 cache" if bypass
  end
end
