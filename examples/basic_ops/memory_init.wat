(module ;; 
    (memory 1)
    (data (i32.const 0) "hello") ;; data segment 0, is active so always copied
    (data "goodbye")             ;; data segment 1, is passive

    (func $start (param $test i32) (result i32)
        (if (local.get $test)
            (then (memory.init 1
                (i32.const 16)
                (i32.const 0)
                (i32.const 7))
                (return (i32.const 1))
            )
        )
        (return (i32.const 0))
    )
    (export "test" (func $start))
)