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