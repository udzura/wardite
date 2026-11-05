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

end
