(module
  ;; Export function that performs basic 4-operation arithmetic loop 10000 times
  (func $arithmetic_loop (export "arithmetic_loop") (result i32)
    (local $i i32)        ;; Loop counter
    (local $a i32)        ;; Arithmetic variable a
    (local $b i32)        ;; Arithmetic variable b
    (local $result i32)   ;; Result storage
    
    ;; Initialize values
    i32.const 0
    local.set $i          ;; i = 0
    
    i32.const 10
    local.set $a          ;; a = 10
    
    i32.const 3
    local.set $b          ;; b = 3
    
    i32.const 0
    local.set $result     ;; result = 0
    
    ;; Start loop
    (loop $main_loop
      ;; Addition: result += a + b
      local.get $result
      local.get $a
      local.get $b
      i32.add
      i32.add
      local.set $result
      
      ;; Subtraction: result += a - b
      local.get $result
      local.get $a
      local.get $b
      i32.sub
      i32.add
      local.set $result
      
      ;; Multiplication: result += a * b
      local.get $result
      local.get $a
      local.get $b
      i32.mul
      i32.add
      local.set $result
      
      ;; Division: result += a / b
      local.get $result
      local.get $a
      local.get $b
      i32.div_s
      i32.add
      local.set $result
      
      ;; Increment counter
      local.get $i
      i32.const 1
      i32.add
      local.set $i
      
      ;; Check loop continuation condition (i < 100000)
      local.get $i
      i32.const 100000
      i32.lt_s
      br_if $main_loop
    )
    
    ;; Return result
    local.get $result
  )
  
  ;; Detailed 4-operation arithmetic function (execute each operation individually)
  (func $detailed_arithmetic (export "detailed_arithmetic") (param $x i32) (param $y i32) (result i32)
    (local $sum i32)
    (local $diff i32)
    (local $product i32)
    (local $quotient i32)
    (local $final_result i32)
    
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
    local.set $final_result
    
    local.get $final_result
  )
  
  ;; Execute detailed_arithmetic with changing numbers 10000 times
  (func $detailed_arithmetic_loop (export "detailed_arithmetic_loop") (result i32)
    (local $i i32)          ;; Loop counter
    (local $x i32)          ;; First argument
    (local $y i32)          ;; Second argument
    (local $total_result i32) ;; Accumulated result
    (local $current_result i32) ;; Current arithmetic result
    
    ;; Initialize values
    i32.const 0
    local.set $i            ;; i = 0
    
    i32.const 5
    local.set $x            ;; x = 5 (initial value)
    
    i32.const 2
    local.set $y            ;; y = 2 (initial value)
    
    i32.const 0
    local.set $total_result ;; total_result = 0
    
    ;; Start loop
    (loop $detailed_loop
      ;; Call detailed_arithmetic function
      local.get $x
      local.get $y
      call $detailed_arithmetic
      local.set $current_result
      
      ;; Accumulate result
      local.get $total_result
      local.get $current_result
      i32.add
      local.set $total_result
      
      ;; Change x and y values (add variation)
      ;; x = x + 1
      local.get $x
      i32.const 1
      i32.add
      local.set $x
      
      ;; y = (y * 2) % 17 + 1 (cycle in range 1-17, avoid zero division)
      local.get $y
      i32.const 2
      i32.mul
      i32.const 17
      i32.rem_s
      i32.const 1
      i32.add
      local.set $y
      
      ;; Limit x to prevent overflow (overflow protection)
      local.get $x
      i32.const 1000
      i32.gt_s
      (if
        (then
          i32.const 1
          local.set $x
        )
      )
      
      ;; Increment counter
      local.get $i
      i32.const 1
      i32.add
      local.set $i
      
      ;; Check loop continuation condition (i < 100000)
      local.get $i
      i32.const 100000
      i32.lt_s
      br_if $detailed_loop
    )
    
    ;; Return accumulated result
    local.get $total_result
  )
  
  ;; Version with more complex pattern for number changes
  (func $detailed_arithmetic_complex_loop (export "detailed_arithmetic_complex_loop") (result i32)
    (local $i i32)          ;; Loop counter
    (local $x i32)          ;; First argument
    (local $y i32)          ;; Second argument
    (local $total_result i32) ;; Accumulated result
    (local $current_result i32) ;; Current arithmetic result
    
    ;; Initialize values
    i32.const 0
    local.set $i            ;; i = 0
    
    i32.const 10
    local.set $x            ;; x = 10 (initial value)
    
    i32.const 3
    local.set $y            ;; y = 3 (initial value)
    
    i32.const 0
    local.set $total_result ;; total_result = 0
    
    ;; Start loop
    (loop $complex_loop
      ;; Call detailed_arithmetic function
      local.get $x
      local.get $y
      call $detailed_arithmetic
      local.set $current_result
      
      ;; Accumulate result
      local.get $total_result
      local.get $current_result
      i32.add
      local.set $total_result
      
      ;; Change numbers with more complex pattern
      ;; x = (x + i) % 100 + 1 (range 1-100)
      local.get $x
      local.get $i
      i32.add
      i32.const 100
      i32.rem_s
      i32.const 1
      i32.add
      local.set $x
      
      ;; y = (i * 3 + 7) % 13 + 1 (range 1-13, avoid zero division)
      local.get $i
      i32.const 3
      i32.mul
      i32.const 7
      i32.add
      i32.const 13
      i32.rem_s
      i32.const 1
      i32.add
      local.set $y
      
      ;; Increment counter
      local.get $i
      i32.const 1
      i32.add
      local.set $i
      
      ;; Check loop continuation condition (i < 100000)
      local.get $i
      i32.const 100000
      i32.lt_s
      br_if $complex_loop
    )
    
    ;; Return accumulated result
    local.get $total_result
  )

  ;; Floating-point 4-operation arithmetic (f32)
  (func $float_arithmetic (export "float_arithmetic") (param $x f32) (param $y f32) (result f32)
    (local $result f32)
    
    ;; Addition
    local.get $x
    local.get $y
    f32.add
    
    ;; Add subtraction
    local.get $x
    local.get $y
    f32.sub
    f32.add
    
    ;; Add multiplication
    local.get $x
    local.get $y
    f32.mul
    f32.add
    
    ;; Add division
    local.get $x
    local.get $y
    f32.div
    f32.add
    
    local.set $result
    local.get $result
  )
)