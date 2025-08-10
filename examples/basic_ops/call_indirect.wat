(module
  ;; ref https://ukyo.github.io/wasm-usui-book/webroot/get-started-webassembly.html
  ;; and https://developer.mozilla.org/ja/docs/WebAssembly/Understanding_the_text_format
  (type $return_i32 (func (result i32)))
  (table 3 funcref)
  (elem (i32.const 0) $f1 $f2 $f3)

  (func $f1 (result i32) i32.const 111)
  (func $f2 (result i32) i32.const 222)
  (func $f3 (result i32) i32.const 333)

  (func (export "call_indirect") (param $i i32) (result i32)
    local.get $i
    call_indirect (type $return_i32))
)