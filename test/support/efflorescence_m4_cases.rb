# frozen_string_literal: true

module EfflorescenceM4Cases
  CONTROL_WAT = <<~WAT.freeze
    (module
      (func $a (param i32 i64) (result i64) (local i64)
        local.get 0 i32.eqz if (result i64)
          local.get 2
        else
          local.get 1 local.set 2
          local.get 0 i32.const 1 i32.sub local.get 1 call $b drop
          local.get 2
        end)
      (func $b (param i32 i64) (result i64)
        local.get 0 local.get 1 call $a)
      (func (export "recursive") (param i32 i64) (result i64)
        local.get 0 local.get 1 call $a
        i32.const 0 i64.const -1 call $a drop)
      (func (export "reset") (param i64) (result i64)
        i32.const 2 local.get 0 call $a drop
        i32.const 0 local.get 0 call $a)
      (func (export "select") (param i64 i32) (result i64)
        local.get 0 i64.const 1 local.tee 0 local.get 1 select)
      (func (export "identity") (param i64) (result i64) local.get 0)
      (func (export "branch") (param i32) (result i64) (local i64)
        block $out (result i32 i64)
          block $in (result i32 i64)
            i32.const 1 i64.const 1 local.get 0 br_table $in $out
          end
          drop i64.const -9223372036854775808
        end
        local.set 1 drop local.get 1)
      (func (export "run") (result i64) i32.const 3 i64.const -9223372036854775808 call $a))
  WAT
end
