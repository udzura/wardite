(module
  (func $simple_math (export "simple_math") (param $x i32) (param $y i32) (result i32)
    local.get $x
    local.get $y
    i32.add

    i32.const 10
    i32.sub

    i32.const 5
    i32.mul

    i32.const 2
    i32.div_s
  )
)