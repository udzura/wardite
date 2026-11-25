# Official core instruction suites

Spinel / Efflorescence with JIT disabled, using Spinel 7289, WABT 1.0.42 and wasm-tools 1.218.0. The runner pins both spec revisions. The 37 scripts keep their original command order. The wg-1.0 script globals.wast is named global.wast in wg-3.0.

Counts include module setup, actions and assertions. One failed module load can cause many later invocations to fail. The wg-3.0 runner checks malformed quoted text with WABT. The wg-1.0 runner retains its existing skips for text-format checks. The wasm-tools version used here required the WABT fallback for align.wast.

| Suite | wg-1.0 pass / fail / skip | wg-3.0 pass / fail / skip |
|---|---:|---:|
| i32 | 443 / 0 / 0 | 460 / 0 / 0 |
| i64 | 389 / 0 / 0 | 416 / 0 / 0 |
| f32 | 2,512 / 0 / 0 | 2,514 / 0 / 0 |
| f64 | 2,512 / 0 / 0 | 2,514 / 0 / 0 |
| f32_bitwise | 364 / 0 / 0 | 364 / 0 / 0 |
| f64_bitwise | 364 / 0 / 0 | 364 / 0 / 0 |
| f32_cmp | 2,407 / 0 / 0 | 2,407 / 0 / 0 |
| f64_cmp | 2,407 / 0 / 0 | 2,407 / 0 / 0 |
| conversions | 435 / 0 / 0 | 619 / 0 / 0 |
| int_exprs | 108 / 0 / 0 | 108 / 0 / 0 |
| float_misc | 441 / 0 / 0 | 471 / 0 / 0 |
| float_memory | 90 / 0 / 0 | 90 / 0 / 0 |
| local_get | 36 / 0 / 0 | 36 / 0 / 0 |
| local_set | 53 / 0 / 0 | 53 / 0 / 0 |
| local_tee | 97 / 0 / 0 | 97 / 1 / 0 |
| global | 78 / 0 / 0 | 47 / 72 / 5 |
| load | 84 / 0 / 13 | 97 / 0 / 0 |
| store | 61 / 0 / 7 | 68 / 0 / 0 |
| address | 242 / 0 / 1 | 259 / 0 / 1 |
| align | 110 / 0 / 46 | 160 / 5 / 0 |
| endianness | 69 / 0 / 0 | 69 / 0 / 0 |
| memory_size | 42 / 0 / 0 | 42 / 0 / 0 |
| memory_grow | 94 / 0 / 0 | 101 / 5 / 0 |
| memory_trap | 173 / 0 / 0 | 182 / 0 / 0 |
| block | 169 / 0 / 2 | 170 / 53 / 0 |
| loop | 79 / 0 / 2 | 34 / 86 / 0 |
| if | 141 / 0 / 10 | 116 / 125 / 0 |
| br | 84 / 0 / 0 | 20 / 77 / 0 |
| br_if | 118 / 0 / 0 | 118 / 1 / 0 |
| br_table | 168 / 0 / 0 | 24 / 159 / 3 |
| return | 84 / 0 / 0 | 84 / 0 / 0 |
| call | 80 / 0 / 2 | 18 / 71 / 2 |
| call_indirect | 139 / 0 / 13 | 36 / 134 / 2 |
| select | 111 / 0 / 0 | 25 / 127 / 5 |
| nop | 88 / 0 / 0 | 88 / 0 / 0 |
| unreachable | 62 / 0 / 0 | 64 / 0 / 0 |
| traps | 36 / 0 / 0 | 36 / 0 / 0 |
| **Total** | **14,970 / 0 / 96** | **14,778 / 916 / 18** |

Before the exception changes, Wardite at fbd8528 recorded 14,970 / 0 / 96 on wg-1.0 and 14,577 / 957 / 178 on wg-3.0. That baseline skipped script registrations, reference expectations and quoted text checks. Changes in skip policy affect the comparison with those baseline counts.

The first module in block, if, br, call and call_indirect requires multiple function results. Loop parameters block the first module in loop. Reference types block the first modules in global, br_table and select. Other failures include memory imports and memory alignment/offset validation.

Two intermediate native builds intermittently reported an unknown MIR optimization while validating wg-1.0 br_if.wast at line 527. The final comparison above includes a full run. The isolated script also passed 16 consecutive runs with the earlier worker.

The wg-3.0 exception scripts are additional to these 37. They pass all 100 commands (tag 10, throw 13, throw_ref 15, try_table 62), including two malformed quoted modules checked by WABT.

~~~sh
bundle exec rake spec
SPEC_VERSION=wg-3.0 bundle exec rake spec
SPEC_VERSION=wg-3.0 bundle exec rake 'spec[exceptions]'
~~~
