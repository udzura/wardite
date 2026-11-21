(module
  ;; A distinguishable error verifies that replay executes the call before
  ;; the following unreachable, using the original argument.
  (func $panic (param i32)
    i32.const 1 local.get 0 i32.rem_u drop)

  (func (export "odd_prime") (param $n i32) (result i32)
    (local $divisor i32)
    block $nonzero
      local.get $n br_if $nonzero
      local.get $n call $panic unreachable
    end
    i32.const 3 local.set $divisor
    block $prime
      loop $trial
        local.get $divisor i64.extend_i32_u
        local.get $divisor i64.extend_i32_u
        i64.mul
        local.get $n i64.extend_i32_u
        i64.gt_u br_if $prime
        block $not_divisible
          local.get $n local.get $divisor i32.rem_u br_if $not_divisible
          i32.const 0 return
        end
        local.get $divisor i32.const 2 i32.add local.set $divisor
        br $trial
      end
    end
    i32.const 1)

  ;; Inputs and destinations in the spill area exercise loads and stores
  ;; with both widths, including a full-width constant with bit 63 set.
  (func (export "wide") (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)
    (local $square i64)
    local.get 0 i64.extend_i32_u local.get 0 i64.extend_i32_u i64.mul
    local.set $square
    local.get $square i64.const 0x8000000000000001 i64.gt_u)
  (func (export "remainder") (param i32 i32) (result i32)
    local.get 0 local.get 1 i32.rem_u))
