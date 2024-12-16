# frozen_string_literal: true
# rbs_inline: enabled

require "test_helper"

class WarditeE2EWasiTest < Test::Unit::TestCase
  test "add(i32, i32)" do
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
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code), enable_wasi: true)
    assert do
      wasm.runtime.call(:_start, []).value == 0
    end
  end
end