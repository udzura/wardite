(module
  ;; Same dependent i32 calculation, either inline or behind a Wasm call.
  ;; Runtime parameters prevent a fixed workload; the returned checksum makes
  ;; every iteration observable. No imports, memory, WASI, or host callbacks.
  (func $mix (param $x i32) (result i32)
    local.get $x
    local.get $x
    i32.const 13
    i32.shr_u
    i32.xor
    i32.const 1664525
    i32.mul
    i32.const 1013904223
    i32.add
    local.set $x
    local.get $x
    local.get $x
    i32.const 7
    i32.shl
    i32.xor)

  (func (export "inline_mix") (param $rounds i32) (param $seed i32) (result i32)
    (local $x i32)
    local.get $seed
    local.set $x
    block $done
      loop $repeat
        local.get $rounds
        i32.eqz
        br_if $done

        local.get $x
        local.get $x
        i32.const 13
        i32.shr_u
        i32.xor
        i32.const 1664525
        i32.mul
        i32.const 1013904223
        i32.add
        local.set $x
        local.get $x
        local.get $x
        i32.const 7
        i32.shl
        i32.xor
        local.set $x

        local.get $rounds
        i32.const 1
        i32.sub
        local.set $rounds
        br $repeat
      end
    end
    local.get $x)

  (func (export "call_mix") (param $rounds i32) (param $seed i32) (result i32)
    (local $x i32)
    local.get $seed
    local.set $x
    block $done
      loop $repeat
        local.get $rounds
        i32.eqz
        br_if $done

        local.get $x
        call $mix
        local.set $x

        local.get $rounds
        i32.const 1
        i32.sub
        local.set $rounds
        br $repeat
      end
    end
    local.get $x)
)
