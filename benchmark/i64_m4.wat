(module
  (memory 1)
  (func $mix (param i64 i32 i64) (result i64)
    local.get 0 local.get 1 i64.extend_i32_u i64.add local.get 2 i64.xor)

  (func (export "alu") (param $n i32) (param $seed i32) (result i64) (local $x i64)
    local.get $seed i64.extend_i32_u local.set $x
    block $done
      loop $repeat
        local.get $n i32.eqz br_if $done
        local.get $x i64.const 6364136223846793005 i64.mul
        i64.const 1442695040888963407 i64.add local.tee $x
        i64.const 29 i64.shr_u local.get $x i64.xor local.set $x
        local.get $n i32.const 1 i32.sub local.set $n
        br $repeat
      end
    end
    local.get $x)

  (func (export "division") (param $n i32) (param $seed i32) (result i64) (local $x i64)
    local.get $seed i64.extend_i32_u local.set $x
    block $done
      loop $repeat
        local.get $n i32.eqz br_if $done
        local.get $x i64.const -1 i64.xor i64.const 7 i64.div_u local.set $x
        local.get $n i32.const 1 i32.sub local.set $n
        br $repeat
      end
    end
    local.get $x)

  (func (export "memory") (param $n i32) (param $seed i32) (result i64) (local $x i64)
    local.get $seed i64.extend_i32_u local.set $x
    block $done
      loop $repeat
        local.get $n i32.eqz br_if $done
        i32.const 1 local.get $x i64.store
        i32.const 1 i64.load i64.const 4294967297 i64.add local.set $x
        local.get $n i32.const 1 i32.sub local.set $n
        br $repeat
      end
    end
    local.get $x)

  (func (export "mixed_call") (param $n i32) (param $seed i32) (result i64) (local $x i64)
    local.get $seed i64.extend_i32_u local.set $x
    block $done
      loop $repeat
        local.get $n i32.eqz br_if $done
        local.get $x local.get $n i64.const 4294967296 call $mix local.set $x
        local.get $n i32.const 1 i32.sub local.set $n
        br $repeat
      end
    end
    local.get $x))
