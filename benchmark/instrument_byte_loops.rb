# frozen_string_literal: true

require "open3"

# Time the bulk encode loop or each PNG row's unfilter call in the
# wardite-benches 921a692 release Wasm. Guest stdout stays byte-identical.
region, input, output = ARGV
abort "Usage: #{$PROGRAM_NAME} encode|png-sub original.wasm timed.wasm" unless %w[encode png-sub].include?(region) && input && output
wat, status = Open3.capture2("wasm2wat", "--generate-names", input)
abort "wasm2wat failed" unless status.success?
if region == "encode"
  func = wat[/^  \(func \$\S*internal_encode .*?(?=^  \()/m] or abort "Missing internal_encode"
  before = "      block $B2\n        block $B3\n          loop $L4\n"
  after = "      end\n      local.get $l10\n      i32.const 24\n"
  abort "Unexpected bulk loop layout" unless [before, after, "br_if $B2\n"].all? { |s| func.scan(s).size == 1 }
  timed = func.sub(before) { "      call $bench_start\n" + before }
  timed = timed.sub(after) { after.sub("      end\n", "      end\n      call $bench_finish\n") }
  wat = wat.sub(func) { timed }
else
  call = /^([ ]*)call (\$\S*3png6filter8unfilter)$/
  abort "Unexpected PNG unfilter call sites" unless wat.scan(call).size == 2
  wat.gsub!(call) { "#{$1}call $bench_start\n#{$1}call #{$2}\n#{$1}call $bench_finish" }
end
wat.sub!("  (import ") do
  '  (import "wasi_snapshot_preview1" "clock_time_get" (func $bench_clock (param i32 i64 i32) (result i32)))' + "\n  (import "
end
# Reserve our own aligned scratch space below the guest stack. Emit both
# little-endian timestamps to stderr after sampling the end of the region.
wat.sub!("  (export ") do
  <<~WAT + "  (export "
    (func $bench_start
      global.get $__stack_pointer i32.const 32 i32.sub global.set $__stack_pointer
      i32.const 1 i64.const 1 global.get $__stack_pointer call $bench_clock if unreachable end)
    (func $bench_finish
      i32.const 1 i64.const 1 global.get $__stack_pointer i32.const 8 i32.add call $bench_clock if unreachable end
      global.get $__stack_pointer global.get $__stack_pointer i32.store offset=16
      global.get $__stack_pointer i32.const 16 i32.store offset=20
      i32.const 2 global.get $__stack_pointer i32.const 16 i32.add i32.const 1
      global.get $__stack_pointer i32.const 24 i32.add call $__imported_wasi_snapshot_preview1_fd_write if unreachable end
      global.get $__stack_pointer i32.const 32 i32.add global.set $__stack_pointer)
  WAT
end
IO.popen(["wat2wasm", "-", "-o", output], "wb") { |io| io.write(wat) }
abort "wat2wasm failed" unless $?.success?
