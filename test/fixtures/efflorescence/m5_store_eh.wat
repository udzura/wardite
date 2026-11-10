(module
  (memory 1)
  (global $f32 (mut f32) (f32.const -nan:0x123))
  (global $f64 (mut f64) (f64.const -nan:0x456))
  (tag $mixed (param i32 f32 i64 f64))
  (func (export "write32") (param i32 i32)
    local.get 0 local.get 1 f32.reinterpret_i32 f32.store offset=1)
  (func (export "write64") (param i32 i64)
    local.get 0 local.get 1 f64.reinterpret_i64 f64.store offset=1)
  (func (export "read32") (param i32) (result i32)
    local.get 0 f32.load offset=1 i32.reinterpret_f32)
  (func (export "read64") (param i32) (result i64)
    local.get 0 f64.load offset=1 i64.reinterpret_f64)
  (func (export "global32") (result i32) global.get $f32 i32.reinterpret_f32)
  (func (export "global64") (result i64) global.get $f64 i64.reinterpret_f64)
  (func (export "update32") (param i32) (result i32)
    global.get $f32
    local.get 0 f32.reinterpret_i32 global.set $f32
    i32.reinterpret_f32)
  (func (export "update64") (param i64) (result i64)
    global.get $f64
    local.get 0 f64.reinterpret_i64 global.set $f64
    i64.reinterpret_f64)
  (func $raise (export "raise")
    i32.const -1 f32.const -nan:0x123 i64.const -7 f64.const -0
    throw $mixed)
  (func $eh (export "eh") (result i32) (local $check i32)
    block $done (result i32 f32 i64 f64)
      try_table (catch $mixed $done)
        block $caught (result i32 f32 i64 f64 exnref)
          try_table (catch_ref $mixed $caught)
            call $raise
          end
          unreachable
        end
        throw_ref
      end
      unreachable
    end
    i64.reinterpret_f64 i64.const 0x8000000000000000 i64.eq
    local.set $check
    i64.const -7 i64.eq local.get $check i32.and local.set $check
    i32.reinterpret_f32 i32.const 0xff800123 i32.eq local.get $check i32.and local.set $check
    i32.const -1 i32.eq local.get $check i32.and)
  (func (export "trap")
    block $caught
      try_table (catch_all $caught)
        f64.const nan i32.trunc_f64_s drop
      end
    end)
  (func (export "repeat_eh") (result i32) call $eh drop call $eh))
