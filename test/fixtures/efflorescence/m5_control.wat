(module
  (func $choose (param i32 f32 i64 f64) (result f64) (local f64)
    block
      local.get 0 i32.eqz br_if 0
      local.get 3 local.set 4
    end
    local.get 4)
  (func (export "reset") (result f64)
    i32.const 1 f32.const nan:0x123 i64.const -1 f64.const -0x0p+0 call $choose drop
    i32.const 0 f32.const -nan:0x124 i64.const -1 f64.const -0x0p+0 call $choose)
  (func (export "choose") (param f32 i32) (result f32)
    block (result f32)
      local.get 0 local.get 1 br_if 0 drop
      f32.const -0x0p+0
    end
    f32.const 0x0p+0 local.get 1 select)
  (func (export "identity") (param f64) (result f64) local.get 0)
  (func (export "constants") (result f32)
    i32.const 0 drop
    f64.const 0 drop
    f32.const 0 drop
    f32.const -0x0p+0 drop
    f32.const -nan:0x123 drop
    f32.const -nan:0x124 drop
    f32.const -nan:0x123)
  (func (export "void") (param f32))
  (func $raw_recursive (param i32 f64) (result f64)
    local.get 0 i32.eqz
    if (result f64)
      local.get 1
    else
      local.get 0 i32.const 1 i32.sub local.get 1 call $raw_recursive
    end)
  (func (export "raw64") (param i32) (result i64)
    i32.const 3 f64.const -nan:0x123 call $raw_recursive
    f64.const nan:0x124 local.get 0 select i64.reinterpret_f64)
  (func (export "parallel") (result i64) (local f64 i64)
    block (result f32 f64)
      f64.const -nan:0x123 local.set 0
      f32.const -nan:0x456 local.get 0
      f64.const 1 local.set 0
      br 0
    end
    i64.reinterpret_f64 local.set 1
    i32.reinterpret_f32 i64.extend_i32_u local.get 1 i64.xor))
