(module ;; https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/Control_flow/br
  (global $i (mut i32) (i32.const 0))

  (func $count (result i32)
    (loop $my_loop (result i32)
      global.get $i
      i32.const 1
      i32.add
      global.set $i

      global.get $i
      global.get $i
      i32.const 10
      i32.lt_s
      br_if $my_loop
    )
  )

  (export "count" (func $count))
)
