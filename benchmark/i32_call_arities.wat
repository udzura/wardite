(module
  ;; Arity-specific CALL transfer. Disable MIR inlining to keep every call.
  (func $zero (result i32) i32.const 7)
  (func $one (param i32) (result i32) local.get 0)
  (func $two (param i32 i32) (result i32)
    local.get 0 local.get 1 i32.add)
  (func $three (param i32 i32 i32) (result i32)
    local.get 0 local.get 1 i32.add local.get 2 i32.sub)
  (func $four (param i32 i32 i32 i32) (result i32)
    local.get 0 local.get 1 i32.add local.get 2 i32.sub local.get 3 i32.add)

  (func (export "empty_loop") (param $rounds i32) (param $seed i32) (result i32)
    (local $x i32)
    local.get $seed local.set $x
    block $done
      loop $repeat
        local.get $rounds i32.eqz br_if $done

        local.get $rounds i32.const 1 i32.sub local.set $rounds
        br $repeat
      end
    end
    local.get $x)

  (func (export "call_zero") (param $rounds i32) (param $seed i32) (result i32)
    (local $x i32)
    local.get $seed local.set $x
    block $done
      loop $repeat
        local.get $rounds i32.eqz br_if $done
        local.get $x call $zero i32.add local.set $x
        local.get $rounds i32.const 1 i32.sub local.set $rounds
        br $repeat
      end
    end
    local.get $x)

  (func (export "call_one") (param $rounds i32) (param $seed i32) (result i32)
    (local $x i32)
    local.get $seed local.set $x
    block $done
      loop $repeat
        local.get $rounds i32.eqz br_if $done
        local.get $x call $one local.set $x
        local.get $rounds i32.const 1 i32.sub local.set $rounds
        br $repeat
      end
    end
    local.get $x)

  (func (export "call_two") (param $rounds i32) (param $seed i32) (result i32)
    (local $x i32)
    local.get $seed local.set $x
    block $done
      loop $repeat
        local.get $rounds i32.eqz br_if $done
        local.get $x i32.const 1 call $two local.set $x
        local.get $rounds i32.const 1 i32.sub local.set $rounds
        br $repeat
      end
    end
    local.get $x)

  (func (export "call_three") (param $rounds i32) (param $seed i32) (result i32)
    (local $x i32)
    local.get $seed local.set $x
    block $done
      loop $repeat
        local.get $rounds i32.eqz br_if $done
        local.get $x i32.const 4 i32.const 1 call $three local.set $x
        local.get $rounds i32.const 1 i32.sub local.set $rounds
        br $repeat
      end
    end
    local.get $x)

  (func (export "call_four") (param $rounds i32) (param $seed i32) (result i32)
    (local $x i32)
    local.get $seed local.set $x
    block $done
      loop $repeat
        local.get $rounds i32.eqz br_if $done
        local.get $x i32.const 4 i32.const 1 i32.const 3 call $four local.set $x
        local.get $rounds i32.const 1 i32.sub local.set $rounds
        br $repeat
      end
    end
    local.get $x)
)
