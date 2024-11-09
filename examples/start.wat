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