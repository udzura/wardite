(module
  (memory 1)
  (func $i32_store
    (i32.const 0)
    (i32.const 42)
    (i32.store)
  )
  (export "i32_store" (func $i32_store))
)