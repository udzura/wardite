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