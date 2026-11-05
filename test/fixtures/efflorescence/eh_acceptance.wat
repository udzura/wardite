(module
  (tag $e (param i32))
  (func $raise i32.const 42 throw $e)
  (func (export "catch_call") (result i32)
    block $done (result i32)
      try_table (catch $e $done) call $raise end
      i32.const 0
    end)
  (func (export "rethrow") (result i32) (local $saved exnref)
    block $outer (result i32)
      try_table (catch $e $outer)
        block $inner (result i32 exnref)
          try_table (catch_ref $e $inner) call $raise end
          unreachable
        end
        local.set $saved drop local.get $saved throw_ref
      end
      i32.const 0
    end))
