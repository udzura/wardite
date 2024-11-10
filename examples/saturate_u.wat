(module
  (global $big (mut f64) (f64.const 50000000000.0))
  (func $main (result i64)
    global.get $big
    i32.trunc_sat_f64_u
    i64.extend_i32_u
  )
  (export "saturate" (func $main))
)