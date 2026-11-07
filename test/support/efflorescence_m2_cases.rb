# frozen_string_literal: true

module EfflorescenceM2Cases
  MODES = [{}, {disabled_optimizations: [:all]}, {disabled_optimizations: [:frames]}, {mir_profile: true}].freeze
  GLOBAL_WAT = <<~WAT.freeze
    (module
      (global $g (export "g") (mut i32) (i32.const 7))
      (global $fixed (export "fixed_global") i32 (i32.const -1))
      (global i64 (i64.const 11)) (global f32 (f32.const 11)) (global f64 (f64.const 11))
      (func $bump global.get $g i32.const 1 i32.add global.set $g)
      (func $sum (param i32) (result i32)
        local.get 0 if (result i32)
          global.get $g call $bump
          local.get 0 i32.const 1 i32.sub call $sum i32.add
        else i32.const 0 end)
      (func (export "get") (result i32) global.get $g)
      (func (export "set") (param i32) local.get 0 global.set $g)
      (func (export "direct") (param i32) (result i32)
        global.get $g local.get 0 global.set $g)
      (func (export "snapshot") (result i32)
        global.get $g call $bump global.get $g i32.sub)
      (func (export "recursive") (param i32) (result i32) local.get 0 call $sum)
      (func (export "fixed") (result i32) global.get $fixed))
  WAT
  MEMORY_WAT = '(module (memory (export "memory") 1) ' + %w[load load8_s load8_u load16_s load16_u].map do |name|
    "(func (export \"#{name}\") (param i32) (result i32) local.get 0 i32.#{name})"
  end.join + %w[store store8 store16].map do |name|
    "(func (export \"#{name}\") (param i32 i32) local.get 0 local.get 1 i32.#{name})"
  end.join + <<~WAT
    (func (export "offset") (param i32) (result i32) local.get 0 i32.load offset=3 align=1)
    (func (export "overflow") (param i32) (result i32) local.get 0 i32.load8_u offset=4294967295)
    (func (export "store_overflow") (param i32) local.get 0 i32.const 42 i32.store8 offset=4294967295)
    (func (export "unused") i32.const 65536 i32.load drop))
  WAT

  GROW_WAT = <<~WAT.freeze
    (module (memory (export "memory") 1 3)
      (data (i32.const 0) "abc")
      (func (export "size") (result i32) memory.size)
      (func (export "grow") (param i32) (result i32) local.get 0 memory.grow)
      (func (export "load") (param i32) (result i32) local.get 0 i32.load8_u)
      (func $callee i32.const 1 memory.grow drop i32.const 65536 i32.const 42 i32.store)
      (func (export "callee") (result i32)
        i32.const 0 i32.const 11 i32.store call $callee
        i32.const 0 i32.load i32.const 65536 i32.load i32.add))
  WAT

  BULK_WAT = <<~WAT.freeze
    (module (memory (export "memory") 1 2)
      (data $active (i32.const 0) "abcdef")
      (data $passive "\\80\\ffABC\\00xyz") (data $empty "")
      (func (export "init") (param i32 i32 i32)
        local.get 0 local.get 1 local.get 2 memory.init $passive)
      (func (export "active") (param i32 i32 i32)
        local.get 0 local.get 1 local.get 2 memory.init $active)
      (func (export "empty") (param i32 i32 i32)
        local.get 0 local.get 1 local.get 2 memory.init $empty)
      (func (export "copy") (param i32 i32 i32)
        local.get 0 local.get 1 local.get 2 memory.copy)
      (func (export "fill") (param i32 i32 i32)
        local.get 0 local.get 1 local.get 2 memory.fill)
      (func (export "load") (param i32) (result i32) local.get 0 i32.load8_u))
  WAT

  INTEGRATION_WAT = <<~WAT.freeze
    (module (tag $e (param i32))
      (memory (export "memory") 1 3)
      (global $g (export "g") (mut i32) (i32.const 3))
      (data (i32.const 0) "x")
      (func $start i32.const 0 i32.const 11 i32.store i32.const 5 global.set $g)
      (start $start)
      (func $thrower i32.const 4 i32.const 40 i32.store i32.const 2 global.set $g i32.const 9 throw $e)
      (func (export "caught") (result i32)
        block $done (result i32)
          try_table (catch $e $done) call $thrower end unreachable
        end global.get $g i32.add i32.const 4 i32.load i32.add)
      (func (export "get") (result i32) global.get $g)
      (func (export "load") (param i32) (result i32) local.get 0 i32.load)
      (func (export "size") (result i32) memory.size)
      (func (export "trap") (result i32)
        block $wrong
          try_table (catch_all $wrong)
            i32.const 31 global.set $g
            i32.const 8 i32.const 73 i32.store
            i32.const 65535 i32.const 7 i32.store
          end
        end i32.const -999)
      (func (export "uncaught")
        i32.const 99 global.set $g i32.const 12 i32.const 44 i32.store i32.const 17 throw $e)
      (func $write i32.const 16 i32.const 50 i32.store i32.const 50 global.set $g)
      (func (export "snapshot") (result i32)
        i32.const 16 i32.const 10 i32.store i32.const 16 i32.load
        call $write i32.const 16 i32.load i32.sub)
      (func $touch (param i32) (result i32) (local i32)
        local.get 0 if i32.const 100 local.set 1 end
        i32.const 20 local.get 1 i32.store local.get 1)
      (func (export "reuse") (result i32) i32.const 1 call $touch drop i32.const 0 call $touch)
      (func $pure (result i32) i32.const 6 i32.const 7 i32.mul)
      (func (export "pure") (result i32) call $pure))
  WAT

end
