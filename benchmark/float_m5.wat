(module
  (func (export "float_alu") (param $n i32) (param $seed i32) (result i64)
    (local $value f32)
    local.get $seed f32.convert_i32_u local.set $value
    block $done
      loop $repeat
        local.get $n i32.eqz br_if $done
        local.get $value f32.const 1.25 f32.add f32.const 1.5 f32.div
        local.set $value
        local.get $n i32.const 1 i32.sub local.set $n
        br $repeat
      end
    end
    local.get $value i32.reinterpret_f32 i64.extend_i32_u)
  (func (export "float_convert") (param $n i32) (param $seed i32) (result i64)
    (local $sum i64)
    local.get $seed i64.extend_i32_u local.set $sum
    block $done
      loop $repeat
        local.get $n i32.eqz br_if $done
        local.get $sum
        local.get $n i64.extend_i32_u f32.convert_i64_u f64.promote_f32 i64.trunc_f64_u
        i64.add local.set $sum
        local.get $n i32.const 1 i32.sub local.set $n
        br $repeat
      end
    end
    local.get $sum)
  (func $step (param i32 f32 i64 f64) (result f64)
    local.get 3 local.get 1 f64.promote_f32 f64.add)
  (func (export "float_mixed_call") (param $n i32) (param $seed i32) (result i64)
    (local $value f64)
    local.get $seed f64.convert_i32_u local.set $value
    block $done
      loop $repeat
        local.get $n f32.const 0.25 i64.const -1 local.get $value
        call $step local.set $value
        local.get $n i32.const 1 i32.sub local.tee $n br_if $repeat
      end
    end
    local.get $value i64.reinterpret_f64)
  (func (export "float_identity") (param f32) (result f32) local.get 0))
