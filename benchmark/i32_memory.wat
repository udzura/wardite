(module
  (memory (export "memory") 1 3)
  (global $g (mut i32) (i32.const 0))
  (data $pattern "0123456789abcdef")

  ;; Initialize 256 words, then scan each complete array once per round.
  (func (export "array_scan") (param $rounds i32) (param $seed i32) (result i32)
    (local $index i32) (local $sum i32)
    loop $initialize
      local.get $index i32.const 2 i32.shl
      local.get $seed local.get $index i32.add i32.store
      local.get $index i32.const 1 i32.add local.tee $index
      i32.const 256 i32.lt_u br_if $initialize
    end
    block $done loop $round
      local.get $rounds i32.eqz br_if $done
      i32.const 0 local.set $index
      loop $scan
        local.get $sum local.get $index i32.const 2 i32.shl i32.load i32.add local.set $sum
        local.get $index i32.const 1 i32.add local.tee $index
        i32.const 256 i32.lt_u br_if $scan
      end
      local.get $rounds i32.const 1 i32.sub local.set $rounds br $round
    end end
    local.get $sum)

  ;; Both a complete fill and an overlapping copy run every iteration.
  (func (export "copy_fill") (param $rounds i32) (param $seed i32) (result i32)
    (local $index i32) (local $sum i32)
    block $done loop $round
      local.get $index local.get $rounds i32.ge_u br_if $done
      i32.const 2048 local.get $seed local.get $index i32.add i32.const 256 memory.fill
      i32.const 2112 i32.const 2048 i32.const 128 memory.copy
      local.get $sum i32.const 2239 i32.load8_u i32.add local.set $sum
      local.get $index i32.const 1 i32.add local.set $index br $round
    end end
    local.get $sum)

  (func (export "global_update") (param $rounds i32) (param $seed i32) (result i32)
    local.get $seed global.set $g
    block $done loop $round
      local.get $rounds i32.eqz br_if $done
      global.get $g i32.const 1664525 i32.add global.set $g
      local.get $rounds i32.const 1 i32.sub local.set $rounds br $round
    end end
    global.get $g)

  (func (export "segment_init") (param $rounds i32) (param $seed i32) (result i32)
    (local $index i32) (local $sum i32)
    local.get $seed local.set $sum
    block $done loop $round
      local.get $index local.get $rounds i32.ge_u br_if $done
      i32.const 4096 i32.const 0 i32.const 16 memory.init $pattern
      local.get $sum i32.const 4096 local.get $index i32.const 15 i32.and i32.add
      i32.load8_u i32.add local.set $sum
      local.get $index i32.const 1 i32.add local.set $index br $round
    end end
    local.get $sum))
