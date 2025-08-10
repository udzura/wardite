(module
  (global $big (mut f64) (f64.const 50000000000.0))
  (func $main (result i32)
    global.get $big
    i32.trunc_sat_f64_s
  )
  (export "saturate" (func $main))
)