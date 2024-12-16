# frozen_string_literal: true
# rbs_inline: enabled

require "test_helper"

class WarditeE2EBasicTest < Test::Unit::TestCase
  test "add(i32, i32)" do
    code = <<~WAT
      (module
        (func (export "add") (param $a i32) (param $b i32) (result i32)
          (local.get $a)
          (local.get $b)
          i32.add
        )
      )
    WAT
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code))
    assert do
      wasm.runtime.call(:add, [100, 200]).value == 300
    end
  end

  test "break" do
    code = <<~WAT
      ;; https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/Control_flow/block
      (module
        (func (export "ret_if_100") (param $num i32) (result i32)
          (block $my_block
            local.get $num
            i32.const 100
            i32.eq
            (if
              (then
                br $my_block))
            i32.const -1
            local.set $num)
          local.get $num))
    WAT
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code))
    assert do
      wasm.runtime.call(:ret_if_100, [100]).value == 100
    end

    assert do
      wasm.runtime.call(:ret_if_100, [10]).value_s == -1
    end
  end

  test "call" do
    code = <<~WAT
      (module
        (func (export "call_doubler") (param i32) (result i32) 
          (local.get 0)
          (call $double)
        )
        (func $double (param i32) (result i32)
          (local.get 0)
          (local.get 0)
          i32.add
        )
      )
    WAT
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code))
    assert do
      wasm.runtime.call(:call_doubler, [123]).value == 246
    end
  end

  test "call_indirect" do
    code = <<~WAT
      (module
        ;; ref https://ukyo.github.io/wasm-usui-book/webroot/get-started-webassembly.html
        ;; and https://developer.mozilla.org/ja/docs/WebAssembly/Understanding_the_text_format
        (type $return_i32 (func (result i32)))
        (table 3 funcref)
        (elem (i32.const 0) $f1 $f2 $f3)

        (func $f1 (result i32) i32.const 111)
        (func $f2 (result i32) i32.const 222)
        (func $f3 (result i32) i32.const 333)

        (func (export "call_indirect") (param $i i32) (result i32)
          local.get $i
          call_indirect (type $return_i32))
      )
    WAT
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code))
    assert do
      wasm.runtime.call(:call_indirect, [0]).value == 111
    end

    assert do
      wasm.runtime.call(:call_indirect, [1]).value == 222
    end

    assert do
      wasm.runtime.call(:call_indirect, [2]).value == 333
    end
  end

  test "consts" do
    code = <<~WAT
      (module
        (func $test_const (result f32)
          (i32.const 42)
          (drop)
          (i64.const 42)
          (drop)
          (f64.const 3.14)
          (drop)
          (f32.const 3.14)
        )
        (export "test_const" (func $test_const))
      )
    WAT
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code))
    assert do
      wasm.runtime.call(:test_const, []).value == 3.140000104904175
    end
  end

  test "fib(i32)" do
    code = <<~WAT
      (module
        (func $fib (export "fib") (param $n i32) (result i32)
          (if
            (i32.lt_s (local.get $n) (i32.const 2))
            (then (return (i32.const 1)))
          )
          (return
            (i32.add
              (call $fib (i32.sub (local.get $n) (i32.const 2)))
              (call $fib (i32.sub (local.get $n) (i32.const 1)))
            )
          )
        )
      )
    WAT
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code))
    assert do
      wasm.runtime.call(:fib, [10]).value == 89
    end
  end

  test "fib2(i32)" do
    code = <<~WAT
      (module
        (func $fib (export "fib") (param i32) (result i32)
          (if (result i32) (i32.le_u (local.get 0) (i32.const 1))
            (then (i32.const 1))
            (else
              (i32.add
                (call $fib (i32.sub (local.get 0) (i32.const 2)))
                (call $fib (i32.sub (local.get 0) (i32.const 1)))
              )
            )
          )
        )
      )
    WAT
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code))
    assert do
      wasm.runtime.call(:fib, [10]).value == 89
    end
  end

  test "global" do
    code = <<~WAT
      (module ;; from https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/Variables/Global_set
        (global $var (mut i32) (i32.const 0))
        (global $var2 (mut i32) (i32.const 40))
        (func $main (result i32)
          i32.const 10 ;; load a number onto the stack
          global.set $var ;; set the $var

          global.get $var ;; load $var onto the stack
          global.get $var2
          i32.add ;; 10 + 40
        )
        (export "test" (func $main))
      )
    WAT
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code))
    assert do
      wasm.runtime.call(:test, []).value == 50
    end
  end

  test "i32_const" do
    code = <<~WAT
      (module
        (func $i32_const (result i32)
          (i32.const 42)
        )
        (export "i32_const" (func $i32_const))
      )
    WAT
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code))
    assert do
      wasm.runtime.call(:i32_const, []).value == 42
    end
  end

  test "i32_store" do
    code = <<~WAT
      (module
        (memory 1)
        (func $i32_store
          (i32.const 0)
          (i32.const 42)
          (i32.store)
        )
        (export "i32_store" (func $i32_store))
      )
    WAT
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code))
    assert do
      wasm.runtime.call(:i32_store, []) == nil
    end
  end

  test "local_set" do
    code = <<~WAT
      (module
        (func $local_set (result i32)
          (local $x i32)
          (local.set $x (i32.const 42))
          (local.get 0)
        )
        (export "local_set" (func $local_set))
      )
    WAT
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code))
    assert do
      wasm.runtime.call(:local_set, []).value == 42
    end
  end

  test "loop" do
    code = <<~WAT
      (module ;; https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/Control_flow/br
        (global $i (mut i32) (i32.const 0))

        (func $count (result i32)
          (loop $my_loop (result i32)
            global.get $i
            i32.const 1
            i32.add
            global.set $i

            global.get $i ;; return value
            global.get $i
            i32.const 10
            i32.lt_s
            br_if $my_loop
          )
        )

        (export "count" (func $count))
      )
    WAT
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code))
    assert do
      wasm.runtime.call(:count, []).value == 10
    end
  end

  test "memory_init" do
    code = <<~WAT
      (module ;; 
          (memory 1)
          (data (i32.const 0) "hello") ;; data segment 0, is active so always copied
          (data "goodbye")             ;; data segment 1, is passive

          (func $start (param $test i32) (result i32)
              (if (local.get $test)
                  (then (memory.init 1
                      (i32.const 16)
                      (i32.const 0)
                      (i32.const 7))
                      (return (i32.const 1))
                  )
              )
              (return (i32.const 0))
          )
          (export "test" (func $start))
      )
    WAT
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code))
    assert do
      wasm.runtime.call(:test, [0]).value == 0
    end

    assert do
      wasm.runtime.call(:test, [1]).value == 1
    end
  end

  test "memory" do
    code = <<~WAT
      (module
        (memory 1)
        (data (i32.const 0) "hello")
        (data (i32.const 5) "world")
      )
    WAT
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code))
    assert do
      wasm.store.memories[0].data[0...10] == "helloworld"
    end
  end

  test "saturate_u" do
    code = <<~WAT
      (module
        (global $big (mut f64) (f64.const 50000000000.0))
        (func $main (result i64)
          global.get $big
          i32.trunc_sat_f64_u
          i64.extend_i32_u
        )
        (export "saturate" (func $main))
      )
    WAT
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code))
    assert do
      wasm.runtime.call(:saturate, []).value == 4294967295
    end
  end

  test "saturate" do
    code = <<~WAT
      (module
        (global $big (mut f64) (f64.const 50000000000.0))
        (func $main (result i32)
          global.get $big
          i32.trunc_sat_f64_s
        )
        (export "saturate" (func $main))
      )
    WAT
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code))
    assert do
      wasm.runtime.call(:saturate, []).value == 2147483647
    end
  end

  test "start" do
    code = <<~WAT
      (module
        (global $var (mut i32) (i32.const 0))
        (func $init
          i32.const 100
          global.set $var
        )
        (func $main (result i32)
          global.get $var ;; load $var onto the stack
        )
        (start $init)
        (export "test" (func $main))
      )
    WAT
    wasm = ::Wardite::BinaryLoader.load_from_buffer(make_buffer_from_wat(code))
    assert do
      wasm.runtime.call(:test, []).value == 100
    end
  end
end
