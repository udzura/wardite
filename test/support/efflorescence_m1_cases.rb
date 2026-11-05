# frozen_string_literal: true

# Shared by CRuby, the native CLI, and the optional external-engine comparison.
module EfflorescenceM1Cases
  ACCEPTANCE = File.read(File.expand_path('../fixtures/efflorescence/eh_acceptance.wat', __dir__)).freeze
  EH_CASES = [
    ["acceptance", ACCEPTANCE, [["catch_call", [], 42], ["rethrow", [], 42]]],
    ["tags and clause order", <<~WAT, [["run", [], 42]]],
      (module
        (tag $e (param i32)) (tag $other (param i32))
        (func (export "run") (result i32)
          block $all
            block $wrong (result i32)
              block $right (result i32)
                try_table (catch $other $wrong) (catch $e $right) (catch_all $all)
                  i32.const 42 throw $e
                end
                unreachable
              end
              return
            end
            drop i32.const 1 return
          end
          i32.const 2))
    WAT
    ["catch_all before typed clause", <<~WAT, [["run", [], 42]]],
      (module (tag $e (param i32))
        (func (export "run") (result i32)
          block $all
            block $typed (result i32)
              try_table (catch_all $all) (catch $e $typed)
                i32.const 9 throw $e
              end unreachable
            end return
          end i32.const 42))
    WAT
    ["zero and multiple payloads", <<~WAT, [["zero", [], 42], ["many", [], 42]]],
      (module (tag $zero) (tag $many (param i32 i32 i32))
        (func (export "zero") (result i32)
          block $done try_table (catch $zero $done) throw $zero end unreachable end
          i32.const 42)
        (func (export "many") (result i32)
          block $done (result i32 i32 i32)
            try_table (catch $many $done)
              i32.const 11 i32.const 3 i32.const 2 throw $many
            end unreachable
          end i32.sub i32.const 31 i32.mul i32.add))
    WAT
    ["empty and mismatching inner handlers", <<~WAT, [["run", [], 42]]],
      (module (tag $e (param i32)) (tag $other (param i32))
        (func (export "run") (result i32)
          block $outer (result i32)
            try_table (catch $e $outer)
              block $inner (result i32)
                try_table (catch $other $inner)
                  try_table i32.const 42 throw $e end
                end unreachable
              end drop
            end i32.const 0
          end))
    WAT
    ["recursive and mutual unwinding with caller locals", <<~WAT, [["run", [30], 42], ["run", [0], 42]]],
      (module (tag $e (param i32))
        (func $a (param i32) (local exnref)
          local.get 0 if local.get 0 i32.const 1 i32.sub call $b
          else i32.const 2 throw $e end)
        (func $b (param i32) local.get 0 call $a)
        (func (export "run") (param i32) (result i32) (local i32)
          block $done (result i32)
            try_table (catch $e $done)
              i32.const 40 local.set 1 local.get 0 call $a
            end unreachable
          end local.get 1 i32.add))
    WAT
    ["normal end and return remove handlers", <<~WAT, [["run", [], 42]]],
      (module (tag $e (param i32))
        (func $return
          block $wrong (result i32)
            try_table (catch $e $wrong) return end unreachable
          end drop unreachable)
        (func (export "run") (result i32)
          block $outer (result i32)
            try_table (catch $e $outer)
              block $wrong (result i32)
                try_table (catch $e $wrong) nop end
                call $return
                i32.const 0 br 0
              end drop
              i32.const 42 throw $e
            end unreachable
          end))
    WAT
    ["taken and non-taken br_if trim only their own edge", <<~WAT, [["run", [0], 42], ["run", [1], 42]]],
      (module (tag $e (param i32))
        (func (export "run") (param i32) (result i32)
          block $outer (result i32)
            try_table (catch $e $outer)
              block $exit
                block $inner (result i32)
                  try_table (catch $e $inner)
                    local.get 0 br_if $exit
                    i32.const 42 throw $e
                  end unreachable
                end return
              end
              i32.const 42 throw $e
            end unreachable
          end))
    WAT
    ["br and br_table remove exited handlers", <<~WAT, [["run", [0], 42], ["run", [1], 42], ["run", [-1], 42]]],
      (module (tag $e (param i32))
        (func (export "run") (param i32) (result i32)
          block $outer (result i32)
            try_table (catch $e $outer)
              block $exit
                block $wrong (result i32)
                  try_table (catch $e $wrong)
                    local.get 0 br_table $exit $exit
                  end unreachable
                end drop unreachable
              end
              i32.const 42 throw $e
            end unreachable
          end))
    WAT
    ["loop backedge retains its enclosing handler", <<~WAT, [["run", [10], 42]]],
      (module (tag $e (param i32))
        (func (export "run") (param i32) (result i32)
          block $done (result i32)
            try_table (catch $e $done)
              loop $again
                local.get 0 if
                  local.get 0 i32.const 1 i32.sub local.set 0 br $again
                end
                i32.const 42 throw $e
              end
            end unreachable
          end))
    WAT
    ["catch targeting a loop removes only the inner handler", <<~WAT, [["run", [], 42]]],
      (module (tag $e) (tag $answer (param i32))
        (func (export "run") (result i32) (local i32)
          block $done (result i32)
            try_table (catch $answer $done)
              loop $again
                local.get 0 if i32.const 42 throw $answer end
                i32.const 1 local.set 0
                try_table (catch $e $again) throw $e end
              end
            end unreachable
          end))
    WAT
    ["saved references survive calls, tee, and snapshots", <<~WAT, [["run", [], 42]]],
      (module (tag $e (param i32))
        (func $other (result i32) i32.const 99)
        (func (export "run") (result i32) (local $saved exnref) (local $null exnref)
          block $outer (result i32)
            try_table (catch $e $outer)
              block $inner (result i32 exnref)
                try_table (catch_ref $e $inner) i32.const 42 throw $e end unreachable
              end
              local.tee $saved drop drop
              local.get $saved
              local.get $null local.set $saved
              call $other drop
              throw_ref
            end unreachable
          end))
    WAT
    ["catch_all_ref rethrows the original tag", <<~WAT, [["run", [], 42]]],
      (module (tag $e (param i32)) (tag $other (param i32))
        (func (export "run") (result i32)
          block $outer (result i32)
            try_table (catch $e $outer)
              block $inner (result exnref)
                try_table (catch_all_ref $inner) i32.const 42 throw $e end unreachable
              end throw_ref
            end unreachable
          end))
    WAT
    ["conditional multi-value reference transfer", <<~WAT, [["run", [0], 42], ["run", [1], 42]]],
      (module (tag $e (param i32))
        (func (export "run") (param i32) (result i32) (local exnref) (local i32)
          block $outer (result i32)
            try_table (catch $e $outer)
              block $caught (result i32 exnref)
                try_table (catch_ref $e $caught) i32.const 42 throw $e end unreachable
              end local.set 1 local.set 2
              block $merge (result i32 exnref)
                local.get 2 local.get 1 local.get 0 br_if $merge
                drop drop local.get 2 local.get 1
              end
              local.set 1 drop local.get 1 throw_ref
            end unreachable
          end))
    WAT
    ["reference and integer multi-value normal joins", <<~WAT, [["run", [0], 42], ["run", [1], 42]]],
      (module (tag $e (param i32))
        (func (export "run") (param i32) (result i32) (local exnref) (local i32)
          block $outer (result i32)
            try_table (catch $e $outer)
              block $caught (result i32 exnref)
                try_table (catch_ref $e $caught) i32.const 42 throw $e end unreachable
              end local.set 1 local.set 2
              local.get 0 if (result i32 exnref)
                local.get 2 local.get 1
              else local.get 2 local.get 1 end
              throw_ref drop
            end unreachable
          end))
    WAT
  ].freeze
end
