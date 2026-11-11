# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require_relative "../support/efflorescence_helper"

class WarditeSpinelWasiTest < Test::Unit::TestCase
  include EfflorescenceHelper

  def setup
    @binary = ENV["WARDITE_SPINEL_BIN"]
    omit "Run make spinel-test to test the native executable" unless @binary
  end

  test "Spinel WASI writes checked results to guest memory and exits with the guest status" do
    wat = <<~WAT
      (module
        (import "wasi_snapshot_preview1" "clock_time_get" (func $clock (param i32 i64 i32) (result i32)))
        (import "wasi_snapshot_preview1" "fd_write" (func $write (param i32 i32 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
        (memory 1)
        (data (i32.const 0) "42\\0a")
        (func (export "_start")
          i32.const 1 i64.const 0 i32.const 24 call $clock if unreachable end
          i32.const 24 i64.load i64.eqz if unreachable end
          i32.const 8 i32.const 0 i32.store
          i32.const 12 i32.const 3 i32.store
          i32.const 1 i32.const 8 i32.const 1 i32.const 65535 call $write
          i32.const 21 i32.ne if unreachable end
          i32.const 1 i32.const 8 i32.const 1 i32.const 16 call $write if unreachable end
          i32.const 16 i32.load i32.const 3 i32.ne if unreachable end
          i32.const 7 call $exit))
    WAT
    Dir.mktmpdir do |dir|
      file = File.join(dir, "wasi.wasm")
      File.binwrite(file, compile_efflorescence_wat(wat))
      [[], ["--new-engine"]].each do |options|
        stdout, stderr, status = Open3.capture3(@binary, *options, "--", file)
        assert_equal 7, status.exitstatus, stderr
        assert_equal "42\n", stdout
      end
      stdout, stderr, status = Open3.capture3(@binary, "--new-engine", "--no-wasi", "--invoke", "_start", "--", file)
      assert_false status.success?
      assert_empty stdout
      assert_include stderr, "module wasi_snapshot_preview1 not found"
    end
  end

  test "Spinel WASI reads a preopened file and translates readlink errors" do
    wat = <<~WAT
      (module
        (import "wasi_snapshot_preview1" "path_readlink" (func $link (param i32 i32 i32 i32 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "path_open" (func $open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "fd_read" (func $read (param i32 i32 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "fd_close" (func $close (param i32) (result i32)))
        (memory 1)
        (data (i32.const 0) "answer")
        (func (export "_start")
          i32.const 3 i32.const 0 i32.const 6 i32.const 64 i32.const 16 i32.const 80 call $link
          i32.const 28 i32.ne if unreachable end
          i32.const 3 i32.const 1 i32.const 0 i32.const 6 i32.const 0 i64.const 2 i64.const 0
          i32.const 0 i32.const 16 call $open if unreachable end
          i32.const 24 i32.const 64 i32.store
          i32.const 28 i32.const 2 i32.store
          i32.const 16 i32.load i32.const 24 i32.const 1 i32.const 32 call $read if unreachable end
          i32.const 32 i32.load i32.const 2 i32.ne if unreachable end
          i32.const 64 i32.load16_u i32.const 12852 i32.ne if unreachable end
          i32.const 16 i32.load call $close if unreachable end))
    WAT
    Dir.mktmpdir do |dir|
      file = File.join(dir, "wasi.wasm")
      File.binwrite(file, compile_efflorescence_wat(wat))
      File.write(File.join(dir, "answer"), "42")
      stdout, stderr, status = Open3.capture3(@binary, "--new-engine", "--mapdir", "#{dir}:/app", "--", file)
      assert status.success?, stderr
      assert_empty stdout
    end
  end
end
