;; https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/Control_flow/block
(module
  (func (export "ret_if_100") (param $num i32) (result i32)
    (block $my_block
      local.get $num
      i32.const 100
      i32.eq
      (if
        (then
          br $my_block))
      i32.const -1
      local.set $num)
    local.get $num))
