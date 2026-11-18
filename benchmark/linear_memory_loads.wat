(module
  (memory 1 5)
  (data (i32.const 1) "\ff\dc\80\7f\05\04\f0\02\01\ae\70\e0\50\c0\30\b0")
  (data (i32.const 33) "\19\a0\3d\90\5c\80\6b\70\7a\60\89\50\98\40\a7\30")

  ;; Grow from one to two pages, leaving one page of reserved capacity in Wardite.
  (func $prepare (param $grow i32)
    local.get $grow
    if i32.const 1 memory.grow drop end)

  ;; An input byte selects the table entry, as in a codec's decoding loop.
  (func (export "lookup8") (param $rounds i32) (param $grow i32) (result i64)
    (local $sum i64)
    local.get $grow call $prepare
    block $done loop $next
      local.get $rounds i32.eqz br_if $done
      local.get $sum
      local.get $rounds i32.const 15 i32.and i32.load8_u offset=1
      i32.const 15 i32.and i64.load8_u offset=33
      i64.add local.set $sum
      local.get $rounds i32.const 1 i32.sub local.set $rounds
      br $next
    end end
    local.get $sum)

  (func (export "unaligned64") (param $rounds i32) (param $grow i32) (result i64)
    (local $sum i64)
    local.get $grow call $prepare
    block $done loop $next
      local.get $rounds i32.eqz br_if $done
      local.get $sum
      local.get $rounds i32.const 7 i32.and i64.load offset=1 align=1
      i64.add local.set $sum
      local.get $rounds i32.const 1 i32.sub local.set $rounds
      br $next
    end end
    local.get $sum)

  (func (export "mixed_width") (param $rounds i32) (param $grow i32) (result i32)
    (local $sum i32)
    local.get $grow call $prepare
    block $done loop $next
      local.get $rounds i32.eqz br_if $done
      local.get $sum
      local.get $rounds i32.const 7 i32.and i32.load offset=1 align=1
      i32.add
      local.get $rounds i32.const 7 i32.and i32.load16_u offset=1 align=1
      i32.add local.set $sum
      local.get $rounds i32.const 1 i32.sub local.set $rounds
      br $next
    end end
    local.get $sum))
