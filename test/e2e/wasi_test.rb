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
