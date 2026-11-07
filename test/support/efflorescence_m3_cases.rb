# frozen_string_literal: true

module EfflorescenceM3Cases
  INDIRECT_WAT = <<~WAT.freeze
    (module
      (type $expected (func (param i32 i32) (result i32)))
      (type $duplicate (func (param i32 i32) (result i32)))
      (import "env" "sum" (func $sum (type $duplicate)))
      (import "env" "wrong" (func $wrong (param i32 i32)))
      (table (export "table") 6 funcref)
      (global $effects (mut i32) (i32.const 0))
      (elem (i32.const 0) func $subtract $sum $wrong $wrong_arity)
      (elem (table 0) (i32.const 5) func $subtract)
      (start $start)
      (func $start i32.const 1 i32.const 2 i32.const 1 call_indirect (type $expected) drop)
      (func $subtract (type $duplicate) local.get 0 local.get 1 i32.sub)
      (func $wrong_arity (param i32) (result i32) unreachable)
      (func $arg (param i32) (result i32)
        global.get $effects i32.const 1 i32.add global.set $effects local.get 0)
      (func (export "effects") (result i32) global.get $effects)
      (func (export "run") (param i32 i32 i32) (result i32)
        local.get 1 call $arg local.get 2 call $arg local.get 0 call_indirect (type $expected)))
  WAT

  REFERENCE_WAT = <<~WAT.freeze
    (module
      (type $expected (func (param i32) (result i32)))
      (type $duplicate (func (param i32) (result i32)))
      (table 4 funcref)
      (tag $error (param i32))
      (elem (i32.const 0) func $normal $throw $mismatch)
      (func $normal (type $duplicate) local.get 0 i32.const 8 i32.add)
      (func $throw (type $expected) local.get 0 throw $error)
      (func $mismatch (result i32) unreachable)
      (func (export "run") (param i32 i32) (result i32)
        block $caught (result i32)
          try_table (result i32) (catch $error $caught)
            local.get 1 local.get 0 call_indirect (type $expected)
            i32.const 1 i32.add
          end
          return
        end
        i32.const 100 i32.add))
  WAT
end
