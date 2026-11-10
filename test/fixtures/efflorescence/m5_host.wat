(module
  (type $mix (func (param i32 f32 i64 f64) (result f32)))
  (import "env" "mix" (func $host (type $mix)))
  (import "env" "echo64" (func $echo64 (param f64) (result f64)))
  (table 4 funcref)
  (elem (i32.const 0) func $host $defined $wrong)
  (func $defined (type $mix) local.get 1)
  (func $wrong (param i32 f64 i64 f32) (result f32) unreachable)
  (export "mix" (func $host))
  (export "echo64" (func $echo64))
  (func (export "direct") (param i32) (result i32)
    local.get 0 f32.const -nan:0x123 i64.const -1 f64.const -0
    call $host i32.reinterpret_f32)
  (func (export "indirect") (param i32 i32) (result i32)
    local.get 1 f32.const -nan:0x123 i64.const -1 f64.const -0
    local.get 0 call_indirect (type $mix) i32.reinterpret_f32)
  (func (export "echo32") (param f32) (result f32) local.get 0)
  (func (export "fail") unreachable))
