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
  (func (export "void") (param f32)))
