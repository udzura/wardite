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

  LOAD_OPS = %w[load load8_s load8_u load16_s load16_u load32_s load32_u].freeze
  STORE_OPS = %w[store store8 store16 store32].freeze
  LOAD_EXPORTS = LOAD_OPS.map do |op|
    %((func (export "#{op}") (param i32) (result i64) local.get 0 i64.#{op}))
  end.join("\n").freeze
  STORE_EXPORTS = STORE_OPS.map do |op|
    %((func (export "#{op}") (param i32 i64) local.get 0 local.get 1 i64.#{op}))
  end.join("\n").freeze

  STORE_EH_WAT = <<~WAT.freeze
    (module
      (memory 1)
      (data (i32.const 1) "\\80\\80\\80\\80\\ff\\ff\\ff\\ff")
      (global $g (mut i64) (i64.const 0x8000000000000000))
      (tag $e (param i32 i64 i32))
      #{LOAD_EXPORTS}
      #{STORE_EXPORTS}
      (func (export "get") (result i64) global.get $g)
      (func (export "snapshot") (param i64) (result i64)
        global.get $g local.get 0 global.set $g)
      (func (export "offset_trap") (param i64)
        block $caught
          try_table (catch_all $caught)
            i32.const 1 local.get 0 i64.store offset=4294967295
          end
        end)
      (func $throw (param i64)
        i32.const -1 local.get 0 i32.const 7 throw $e)
      (func $rethrow (export "uncaught") (param i64) (local exnref)
        block $caught (result i32 i64 i32 exnref)
          try_table (catch_ref $e $caught)
            local.get 0 call $throw
          end
          unreachable
        end
        local.set 1 drop drop drop local.get 1 throw_ref)
      (func (export "eh") (param i64) (result i64)
        block $caught (result i32 i64 i32)
          try_table (catch $e $caught)
            local.get 0 call $rethrow
          end
          unreachable
        end
        i32.const 7 i32.ne if unreachable end
        local.set 0
        i32.const -1 i32.ne if unreachable end
        local.get 0))
  WAT

  STORE_EH_ROWS = [
    ["load", 1, -0x7f7f7f80],
    ["load8_s", 1, -128], ["load8_u", 1, 128],
    ["load16_s", 1, -32640], ["load16_u", 1, 32896],
    ["load32_s", 1, -0x7f7f7f80], ["load32_u", 1, 0x80808080],
    ["store", 65528, -0x123456789abcdf0, "void"],
    ["load", 65528, -0x123456789abcdf0],
    ["store8", 65535, -128, "void"], ["load8_s", 65535, -128],
    ["store16", 65534, -32768, "void"], ["load16_u", 65534, 32768],
    ["store32", 65532, 0xffffffff, "void"], ["load32_s", 65532, -1],
    ["load", 65529, "bounds"], ["store", 65529, 0, "bounds"],
    ["offset_trap", -1, "bounds"], ["load32_s", 65532, -1],
    ["get", -2**63], ["snapshot", -1, -2**63], ["get", -1],
    ["eh", -2**63, -2**63], ["uncaught", -2**63, "uncaught"],
    ["eh", -1, -1], ["uncaught", -1, "uncaught"]
  ].freeze
end
