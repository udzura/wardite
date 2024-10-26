(module
  (func (export "call_doubler") (param i32) (result i32) 
    (local.get 0)
    (call $double)
  )
  (func $double (param i32) (result i32)
    (local.get 0)
    (local.get 0)
    i32.add
  )
)