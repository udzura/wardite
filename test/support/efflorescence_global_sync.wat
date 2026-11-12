(module
  (import "env" "update" (func $host (param i32)))
  (global $i32 (mut i32) (i32.const 0))
  (global $i64 (mut i64) (i64.const 0))
  (global $f32 (mut f32) (f32.const 0))
  (global $f64 (mut f64) (f64.const 0))
  (tag $error)
  (func $start i32.const 7 global.set $i32)
  (start $start)
  (func (export "get") (result i32) global.get $i32)
  (func (export "set") (param i32) local.get 0 global.set $i32)
  (func (export "through_host") (param i32) (result i32)
    i32.const 10 global.set $i32
    local.get 0 call $host
    global.get $i32)
  (func (export "trap")
    i32.const 21 global.set $i32 unreachable)
  (func (export "throw")
    i32.const 31 global.set $i32 throw $error)
  (func (export "set_typed")
    i64.const -9223372036854775808 global.set $i64
    f32.const -nan:0x412345 global.set $f32
    f64.const -nan:0x8abcdef012345 global.set $f64)
  (func (export "get_i64") (result i64) global.get $i64)
  (func (export "get_f32_bits") (result i32) global.get $f32 i32.reinterpret_f32)
  (func (export "get_f64_bits") (result i64) global.get $f64 i64.reinterpret_f64))
