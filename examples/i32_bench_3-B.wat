(module
  ;; Detailed 4-operation arithmetic function (execute each operation individually)
  (func $detailed_arithmetic (export "detailed_arithmetic") (param $x i32) (param $y i32) (result i32)
    (local $i i32)
    (local $sum i32)
    (local $diff i32)
    (local $product i32)
    (local $quotient i32)
    (local $result i32)
    (local $final_result i32)
    
    i32.const 0
    local.set $final_result

    i32.const 0
    local.set $i

    (loop $detailed_loop
      ;; Addition
      local.get $x
      local.get $y
      i32.add
      local.set $sum
      
      ;; Subtraction
      local.get $x
      local.get $y
      i32.sub
      local.set $diff
      
      ;; Multiplication
      local.get $x
      local.get $y
      i32.mul
      local.set $product

      ;; Addition
      local.get $x
      local.get $y
      i32.add
      local.set $sum
      
      ;; Subtraction
      local.get $x
      local.get $y
      i32.sub
      local.set $diff
      
      ;; Multiplication
      local.get $x
      local.get $y
      i32.mul
      local.set $product
      ;; Addition
      local.get $x
      local.get $y
      i32.add
      local.set $sum
      
      ;; Subtraction
      local.get $x
      local.get $y
      i32.sub
      local.set $diff
      
      ;; Multiplication
      local.get $x
      local.get $y
      i32.mul
      local.set $product
      ;; Addition
      local.get $x
      local.get $y
      i32.add
      local.set $sum
      
      ;; Subtraction
      local.get $x
      local.get $y
      i32.sub
      local.set $diff
      
      ;; Multiplication
      local.get $x
      local.get $y
      i32.mul
      local.set $product
      ;; Addition
      local.get $x
      local.get $y
      i32.add
      local.set $sum
      
      ;; Subtraction
      local.get $x
      local.get $y
      i32.sub
      local.set $diff
      
      ;; Multiplication
      local.get $x
      local.get $y
      i32.mul
      local.set $product
      ;; Addition
      local.get $x
      local.get $y
      i32.add
      local.set $sum
      
      ;; Subtraction
      local.get $x
      local.get $y
      i32.sub
      local.set $diff
      
      ;; Multiplication
      local.get $x
      local.get $y
      i32.mul
      local.set $product
      ;; Addition
      local.get $x
      local.get $y
      i32.add
      local.set $sum
      
      ;; Subtraction
      local.get $x
      local.get $y
      i32.sub
      local.set $diff
      
      ;; Multiplication
      local.get $x
      local.get $y
      i32.mul
      local.set $product
      ;; Addition
      local.get $x
      local.get $y
      i32.add
      local.set $sum
      
      ;; Subtraction
      local.get $x
      local.get $y
      i32.sub
      local.set $diff
      
      ;; Multiplication
      local.get $x
      local.get $y
      i32.mul
      local.set $product
      ;; Addition
      local.get $x
      local.get $y
      i32.add
      local.set $sum
      
      ;; Subtraction
      local.get $x
      local.get $y
      i32.sub
      local.set $diff
      
      ;; Multiplication
      local.get $x
      local.get $y
      i32.mul
      local.set $product

      ;; Division (with zero division check)
      local.get $y
      i32.const 0
      i32.eq
      (if
        (then
          i32.const 0
          local.set $quotient
        )
        (else
          local.get $x
          local.get $y
          i32.div_s
          local.set $quotient
        )
      )
      
      ;; Sum all results
      local.get $sum
      local.get $diff
      i32.add
      local.get $product
      i32.add
      local.get $quotient
      i32.add
      local.get $final_result
      i32.add
      local.set $final_result

      local.get $i
      i32.const 1
      i32.add
      local.set $i
      
      local.get $i
      i32.const 300000
      i32.lt_s
      br_if $detailed_loop
    )

    local.get $final_result
  )
  
  ;; Execute detailed_arithmetic with changing numbers 10000 times
  (func $detailed_arithmetic_loop (export "detailed_arithmetic_loop") (result i32)
    (local $x i32)          ;; First argument
    (local $y i32)          ;; Second argument
    
    i32.const 998
    local.set $x            ;; x = 5 (initial value)
    
    i32.const 999
    local.set $y            ;; y = 2 (initial value)

    local.get $x
    local.get $y
    call $detailed_arithmetic
  )
)