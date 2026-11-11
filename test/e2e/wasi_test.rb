# frozen_string_literal: true
# rbs_inline: enabled

require "test_helper"
require_relative "../support/efflorescence_helper"

class WarditeE2EWasiTest < Test::Unit::TestCase
  include EfflorescenceHelper

  ROOT = File.expand_path("../..", __dir__)

  test "fd_write uses the instance memory and writes errno, byte count and stdout" do
    code = <<~WAT
      (module
        (import "wasi_snapshot_preview1" "fd_write"
          (func $fd_write (param i32 i32 i32 i32) (result i32))
        )
        (memory 1)
        (data (i32.const 0) "Hello, World!\\n")

        (func $helloworld (result i32)
          (local $iovs i32)

          (i32.store (i32.const 16) (i32.const 0))
          (i32.store (i32.const 20) (i32.const 14))

          (local.set $iovs (i32.const 16))

          (call $fd_write
            (i32.const 1)
            (local.get $iovs)
            (i32.const 1)
            (i32.const 24)
          )
        )
        (export "_start" (func $helloworld))
      )
    WAT
    with_wasm(code) do |file|
      [:stack, :efflorescence].each do |engine|
        script = <<~RUBY
          require "wardite"
          instance = Wardite.new(path: ARGV.fetch(0), engine: ARGV.fetch(1).to_sym)
          errno = instance.runtime.call(:_start, []).value
          nwritten = instance.store.memories.fetch(0).data.byteslice(24, 4).unpack1("V")
          warn [errno, nwritten].join(",")
        RUBY
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{ROOT}/lib", "-e", script, file, engine.to_s)
        assert status.success?, stderr
        assert_equal "Hello, World!\n", stdout
        assert_equal "0,14\n", stderr
      end
    end
  end

  test "Efflorescence fd_write handles indirect calls, reexports and invalid guest ranges" do
    with_wasm(<<~WAT) do |file|
      (module
        (type $write (func (param i32 i32 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "fd_write" (func $write (type $write)))
        (export "write" (func $write))
        (table 1 funcref)
        (elem (i32.const 0) func $write)
        (memory 1)
        (func (export "indirect") (param i32 i32 i32 i32) (result i32)
          local.get 0 local.get 1 local.get 2 local.get 3 i32.const 0 call_indirect (type $write)))
    WAT
      instance = Wardite.new(path: file, engine: :efflorescence, mir_profile: true)
      assert_instance_of Wardite::Efflorescence::WasiSnapshotPreview1, instance.wasi
      vm = instance.runtime
      assert_not_nil vm.ir.hosts.fetch(0).unboxed_wasi

      output = StringIO.new("".b)
      instance.wasi.fd_table[1] = output
      data = instance.store.memories.fetch(0).data
      data[16, 16] = [32, 2, 34, 3].pack("V4")
      data[32, 5] = "abcde"
      assert_equal 0, vm.call_unboxed(:indirect, [1, 16, 2, 64])
      assert_equal "abcde", output.string
      assert_equal 5, data.unpack1("V", offset: 64)
      assert_equal 1, vm.metrics.host_calls
      assert_equal 1, vm.metrics.indirect_calls

      data[34, 1] = "Z"
      assert_equal 0, vm.call(:write, [1, 24, 1, 64]).value
      assert_equal "abcdeZde", output.string
      assert_equal 3, data.unpack1("V", offset: 64)
      assert_equal 1, vm.metrics.host_calls
      assert_equal 0, vm.metrics.frames_created

      assert_equal Wardite::Wasi::EBADF, vm.call_unboxed(:write, [99, 16, 2, 64])
      assert_equal Wardite::Wasi::EFAULT, vm.call_unboxed(:write, [1, -1, 1, 64])
      assert_equal Wardite::Wasi::EFAULT, vm.call_unboxed(:write, [1, 16, -1, 64])
      assert_equal Wardite::Wasi::EFAULT, vm.call_unboxed(:write, [1, 16, 2, 65533])
      data[24, 8] = [65535, 2].pack("V2")
      assert_equal Wardite::Wasi::EFAULT, vm.call_unboxed(:write, [1, 16, 2, 64])
      assert_equal "abcdeZde", output.string
      assert_equal 3, data.unpack1("V", offset: 64)

      assert_equal 0, vm.call_unboxed(:write, [1, 65536, 0, 65532])
      assert_equal 0, data.unpack1("V", offset: 65532)

      memory = instance.store.memories.fetch(0)
      memory.grow(1)
      memory.data[24, 8] = [65536, 1].pack("V2")
      memory.data.setbyte(65536, "x".ord)
      assert_equal 0, vm.call_unboxed(:write, [1, 24, 1, 65537])
      assert_equal 1, memory.data.unpack1("V", offset: 65537)
      assert_equal "abcdeZdex", output.string
    end
  end

  test "native WASI signatures are checked at link time and user modules keep the boxed ABI" do
    ["fd_write", "proc_exit", "clock_res_get", "fd_seek"].each do |name|
      with_wasm(<<~WAT) do |file|
        (module
          (import "wasi_snapshot_preview1" "#{name}" (func $host (result i32)))
          (export "run" (func $host)))
      WAT
        [:stack, :efflorescence].each do |engine|
          assert_raise_message(/invalid WASI signature for #{name}/) { Wardite.new(path: file, engine: engine) }
        end
        host = ->(_store, args) { assert_equal [], args; Wardite::I32.new(37) }
        instance = Wardite.new(path: file, engine: :efflorescence, enable_wasi: false,
          import_object: {wasi_snapshot_preview1: {name.to_sym => host}})
        assert_nil instance.runtime.ir.hosts.fetch(0).unboxed_wasi
        assert_equal 37, instance.runtime.call_unboxed(:run, [])
      end
    end
    with_wasm('(module (import "wasi_snapshot_preview1" "fd_write_from_registers" (func)))') do |file|
      [:stack, :efflorescence].each do |engine|
        assert_raise_message(/unknown WASI import fd_write_from_registers/) { Wardite.new(path: file, engine: engine) }
      end
    end
  end

  test "known unimplemented WASI calls return ENOSYS without touching memory" do
    with_wasm(<<~WAT) do |file|
      (module
        (import "wasi_snapshot_preview1" "fd_seek" (func $seek (param i32 i64 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "poll_oneoff" (func $poll (param i32 i32 i32 i32) (result i32)))
        (memory 1)
        (func (export "seek") (result i32)
          i32.const 1 i64.const -1 i32.const 0 i32.const 0 call $seek)
        (func (export "poll") (result i32)
          i32.const 0 i32.const 0 i32.const 0 i32.const 0 call $poll))
    WAT
      [:stack, :efflorescence].each do |engine|
        instance = Wardite.new(path: file, engine: engine)
        data = instance.store.memories.fetch(0).data
        data[0, 8] = "sentinel"
        assert_equal Wardite::Wasi::ENOSYS, instance.runtime.call(:seek, []).value
        assert_equal Wardite::Wasi::ENOSYS, instance.runtime.call(:poll, []).value
        assert_equal "sentinel", data.byteslice(0, 8)
      end
    end
  end

  test "WASI clock results are nanoseconds and invalid outputs leave memory alone" do
    with_wasm(<<~WAT) do |file|
      (module
        (import "wasi_snapshot_preview1" "clock_res_get" (func $res (param i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "clock_time_get" (func $time (param i32 i64 i32) (result i32)))
        (memory 1)
        (func (export "res") (param i32 i32) (result i32) local.get 0 local.get 1 call $res)
        (func (export "time") (param i32 i32) (result i32)
          local.get 0 i64.const 0 local.get 1 call $time))
    WAT
      instance = Wardite.new(path: file, engine: :efflorescence)
      vm = instance.runtime
      data = instance.store.memories.fetch(0).data
      [Process::CLOCK_REALTIME, Process::CLOCK_MONOTONIC].each_with_index do |clock, id|
        data[0, 10] = "x" * 10
        assert_equal 0, vm.call_unboxed(:res, [id, 1])
        assert_equal Process.clock_getres(clock, :nanosecond), data.unpack1("Q<", offset: 1)
        before = Process.clock_gettime(clock, :nanosecond)
        assert_equal 0, vm.call_unboxed(:time, [id, 1])
        after = Process.clock_gettime(clock, :nanosecond)
        assert_includes before..after, data.unpack1("Q<", offset: 1)
        assert_equal ["x", "x"], [data[0], data[9]]
      end
      before = data.dup
      assert_equal Wardite::Wasi::EINVAL, vm.call_unboxed(:time, [99, 1])
      assert_equal Wardite::Wasi::EFAULT, vm.call_unboxed(:res, [0, 65529])
      assert_equal Wardite::Wasi::EFAULT, vm.call_unboxed(:time, [1, -1])
      assert_equal before, data
    end
  end

  test "WASI environment and fdstat use the Preview 1 byte layouts" do
    with_wasm(<<~WAT) do |file|
      (module
        (import "wasi_snapshot_preview1" "environ_sizes_get" (func $sizes (param i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "environ_get" (func $env (param i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "fd_fdstat_get" (func $fdstat (param i32 i32) (result i32)))
        (export "sizes" (func $sizes))
        (export "env" (func $env))
        (export "fdstat" (func $fdstat))
        (memory 1))
    WAT
      instance = Wardite.new(path: file, engine: :efflorescence)
      vm = instance.runtime
      data = instance.store.memories.fetch(0).data
      original_env = ENV.to_h
      begin
        ENV.replace("A" => "日本語", "B" => "")
        payload = "A=日本語\0B=\0".b
        data[40, payload.bytesize + 1] = "x" * (payload.bytesize + 1)
        assert_equal 0, vm.call_unboxed(:sizes, [1, 5])
        assert_equal [2, payload.bytesize], data.byteslice(1, 8).unpack("V2")
        assert_equal 0, vm.call_unboxed(:env, [16, 40])
        assert_equal [40, 40 + "A=日本語\0".bytesize], data.byteslice(16, 8).unpack("V2")
        assert_equal payload + "x", data.byteslice(40, payload.bytesize + 1)
        before = data.dup
        assert_equal Wardite::Wasi::EFAULT, vm.call_unboxed(:env, [16, 65535])
        assert_equal before, data

        ENV.clear
        assert_equal 0, vm.call_unboxed(:sizes, [1, 5])
        assert_equal [0, 0], data.byteslice(1, 8).unpack("V2")
        before = data.dup
        assert_equal 0, vm.call_unboxed(:env, [65536, 65536])
        assert_equal before, data
      ensure
        ENV.replace(original_env)
      end

      Dir.mktmpdir do |dir|
        instance.wasi.set_preopened_dir("/app", dir)
        data[99, 26] = "x" * 26
        assert_equal 0, vm.call_unboxed(:fdstat, [3, 100])
        rights = Wardite::Wasi::RIGHT_DIR_RIGHT_BASE
        assert_equal [Wardite::Wasi::FILETYPE_DIRECTORY, 0, rights, rights | Wardite::Wasi::RIGHT_FILE_RIGHT_BASE],
          data.byteslice(100, 24).unpack("CxS<x4Q<2")
        assert_equal ["x", "x"], [data[99], data[124]]
        before = data.dup
        assert_equal Wardite::Wasi::EFAULT, vm.call_unboxed(:fdstat, [3, 65513])
        assert_equal before, data
      end
    end
  end

  test "Efflorescence uses the same WASI state for existing boxed calls" do
    with_wasm(<<~WAT) do |file|
      (module
        (import "wasi_snapshot_preview1" "args_sizes_get" (func $sizes (param i32 i32) (result i32)))
        (export "sizes" (func $sizes))
        (memory 1))
    WAT
      instance = Wardite.new(path: file, engine: :efflorescence)
      instance.wasi.argv = ["app", "arg"]
      assert_nil instance.runtime.ir.hosts.fetch(0).unboxed_wasi
      assert_equal 0, instance.runtime.call_unboxed(:sizes, [0, 4])
      data = instance.store.memories.fetch(0).data
      assert_equal [2, 8], data.unpack("V2")
    end
  end

  test "Efflorescence proc_exit reaches the child process boundary" do
    with_wasm(<<~WAT) do |file|
      (module
        (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
        (func (export "_start") i32.const 29 call $exit unreachable))
    WAT
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{ROOT}/lib", "#{ROOT}/exe/wardite", "--new-engine", file)
      assert_equal 29, status.exitstatus, stderr
      assert_equal "", stdout
      assert_equal "", stderr
    end
  end

  test "ordinary imports do not load WASI with default options" do
    with_wasm('(module (import "env" "f" (func $f)) (export "f" (func $f)))') do |file|
      script = <<~RUBY
        require "wardite"
        instance = Wardite.new(path: ARGV.fetch(0), engine: :efflorescence, import_object: {env: {f: ->(_, _) { nil }}})
        abort "WASI was loaded" if defined?(Wardite::WasiSnapshotPreview1) || instance.wasi
        instance.runtime.call(:f, [])
      RUBY
      output, status = Open3.capture2e(RbConfig.ruby, "-I#{ROOT}/lib", "-e", script, file)
      assert status.success?, output
    end
  end

  def with_wasm(wat)
    Dir.mktmpdir("wardite-wasi") do |dir|
      file = File.join(dir, "input.wasm")
      File.binwrite(file, compile_efflorescence_wat(wat))
      yield file
    end
  end
end
