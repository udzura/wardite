(module
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
    i32.const 998
    local.set $i            ;; i = 0
    
    i32.const 999
    local.set $x            ;; x = 5 (initial value)
    
    i32.const 999
    local.set $y            ;; y = 2 (initial value)
    
    i32.const 999
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
      i32.const 1999
      i32.add
      local.set $x
      
      ;; y = (y * 2) % 17 + 1 (cycle in range 1-17, avoid zero division)
      local.get $y
      i32.const 1999
      i32.mul
      i32.const 1777
      i32.rem_s
      i32.const 11234
      i32.add
      local.set $y
      
      ;; Limit x to prevent overflow (overflow protection)
      local.get $x
      i32.const 1000000
      i32.gt_s
      (if
        (then
          i32.const 998
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
)