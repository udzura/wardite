# WebAssembly wg-3.0 suite coverage in Wardite

[日本語版](wg-3.0-suite-coverage-ja.md)

Wardite at commit `9e1d31a` ran all 258 `.wast` files under `test/core`. All 21,228 cases in the 97 top-level suites passed. The four exception suites recorded 98 passes and two failures. At lines 49 and 60 of `exceptions/tag.wast`, Wardite rejected the import during linking as expected. Both assertions expected the diagnostic `incompatible import` and received `incompatible import type`. [Official tests at the pinned revision](https://github.com/WebAssembly/spec/tree/9d36019973201a19f9c9ebb0f10828b2fe2374aa/test/core)

After adding `data.drop`, Wardite passed all 7,463 cases in a rerun of the eight `bulk-memory/` suites. The tables below include those results.

| Group | Suites | All passed | Skips only, no failures | Has failures | Inconclusive |
|---|---:|---:|---:|---:|---:|
| Basic 37 suites | 37 | 37 | 0 | 0 | 0 |
| Other top-level suites | 60 | 60 | 0 | 0 | 0 |
| exceptions | 4 | 3 | 0 | 1 | 0 |
| bulk-memory | 8 | 8 | 0 | 0 | 0 |
| multi-memory | 41 | 40 | 0 | 1 | 0 |
| memory64 | 25 | 0 | 0 | 25 | 0 |
| gc | 17 | 0 | 0 | 16 | 1 |
| simd | 59 | 0 | 0 | 59 | 0 |
| relaxed-simd | 7 | 0 | 0 | 7 | 0 |
| Total | 258 | 148 | 0 | 109 | 1 |

Each file counts as one suite. Case counts include module loads, invocations, checks that invalid modules are rejected, and text syntax checks. A failed module load and each subsequent invocation that fails count separately.

The run used Spinel 7289 with Efflorescence (JIT disabled), wasm-tools 1.236.0, and WABT 1.0.42. With `SPEC_CORE_DIR` pointing to the pinned `test/core` directory, `CoreSpec.run` ran each file in a separate temporary directory and worker process. Commands ran in source order within each suite.

The result for `gc/extern.wast` is inconclusive. The runner raised a `KeyError` while reading an expected reference value.

## Basic 37 suites

| Suite | Result | Passed | Failed | Skipped |
|---|---|---:|---:|---:|
| `address.wast` | All passed | 260 | 0 | 0 |
| `align.wast` | All passed | 165 | 0 | 0 |
| `block.wast` | All passed | 223 | 0 | 0 |
| `br.wast` | All passed | 97 | 0 | 0 |
| `br_if.wast` | All passed | 119 | 0 | 0 |
| `br_table.wast` | All passed | 186 | 0 | 0 |
| `call.wast` | All passed | 91 | 0 | 0 |
| `call_indirect.wast` | All passed | 172 | 0 | 0 |
| `conversions.wast` | All passed | 619 | 0 | 0 |
| `endianness.wast` | All passed | 69 | 0 | 0 |
| `f32.wast` | All passed | 2514 | 0 | 0 |
| `f32_bitwise.wast` | All passed | 364 | 0 | 0 |
| `f32_cmp.wast` | All passed | 2407 | 0 | 0 |
| `f64.wast` | All passed | 2514 | 0 | 0 |
| `f64_bitwise.wast` | All passed | 364 | 0 | 0 |
| `f64_cmp.wast` | All passed | 2407 | 0 | 0 |
| `float_memory.wast` | All passed | 90 | 0 | 0 |
| `float_misc.wast` | All passed | 471 | 0 | 0 |
| `global.wast` | All passed | 124 | 0 | 0 |
| `i32.wast` | All passed | 460 | 0 | 0 |
| `i64.wast` | All passed | 416 | 0 | 0 |
| `if.wast` | All passed | 241 | 0 | 0 |
| `int_exprs.wast` | All passed | 108 | 0 | 0 |
| `load.wast` | All passed | 97 | 0 | 0 |
| `local_get.wast` | All passed | 36 | 0 | 0 |
| `local_set.wast` | All passed | 53 | 0 | 0 |
| `local_tee.wast` | All passed | 98 | 0 | 0 |
| `loop.wast` | All passed | 120 | 0 | 0 |
| `memory_grow.wast` | All passed | 106 | 0 | 0 |
| `memory_size.wast` | All passed | 42 | 0 | 0 |
| `memory_trap.wast` | All passed | 182 | 0 | 0 |
| `nop.wast` | All passed | 88 | 0 | 0 |
| `return.wast` | All passed | 84 | 0 | 0 |
| `select.wast` | All passed | 157 | 0 | 0 |
| `store.wast` | All passed | 68 | 0 | 0 |
| `traps.wast` | All passed | 36 | 0 | 0 |
| `unreachable.wast` | All passed | 64 | 0 | 0 |

## Other top-level suites

| Suite | Result | Passed | Failed | Skipped |
|---|---|---:|---:|---:|
| `annotations.wast` | All passed | 74 | 0 | 0 |
| `binary-leb128.wast` | All passed | 91 | 0 | 0 |
| `binary.wast` | All passed | 127 | 0 | 0 |
| `br_on_non_null.wast` | All passed | 12 | 0 | 0 |
| `br_on_null.wast` | All passed | 10 | 0 | 0 |
| `call_ref.wast` | All passed | 35 | 0 | 0 |
| `comments.wast` | All passed | 8 | 0 | 0 |
| `const.wast` | All passed | 778 | 0 | 0 |
| `custom.wast` | All passed | 11 | 0 | 0 |
| `data.wast` | All passed | 65 | 0 | 0 |
| `elem.wast` | All passed | 151 | 0 | 0 |
| `exports.wast` | All passed | 97 | 0 | 0 |
| `fac.wast` | All passed | 8 | 0 | 0 |
| `float_exprs.wast` | All passed | 927 | 0 | 0 |
| `float_literals.wast` | All passed | 179 | 0 | 0 |
| `forward.wast` | All passed | 5 | 0 | 0 |
| `func.wast` | All passed | 175 | 0 | 0 |
| `func_ptrs.wast` | All passed | 36 | 0 | 0 |
| `id.wast` | All passed | 7 | 0 | 0 |
| `imports.wast` | All passed | 218 | 0 | 0 |
| `inline-module.wast` | All passed | 1 | 0 | 0 |
| `instance.wast` | All passed | 23 | 0 | 0 |
| `int_literals.wast` | All passed | 51 | 0 | 0 |
| `labels.wast` | All passed | 29 | 0 | 0 |
| `left-to-right.wast` | All passed | 96 | 0 | 0 |
| `linking.wast` | All passed | 163 | 0 | 0 |
| `local_init.wast` | All passed | 10 | 0 | 0 |
| `memory.wast` | All passed | 90 | 0 | 0 |
| `memory_redundancy.wast` | All passed | 8 | 0 | 0 |
| `names.wast` | All passed | 486 | 0 | 0 |
| `obsolete-keywords.wast` | All passed | 11 | 0 | 0 |
| `ref.wast` | All passed | 13 | 0 | 0 |
| `ref_as_non_null.wast` | All passed | 7 | 0 | 0 |
| `ref_func.wast` | All passed | 17 | 0 | 0 |
| `ref_is_null.wast` | All passed | 22 | 0 | 0 |
| `ref_null.wast` | All passed | 34 | 0 | 0 |
| `return_call.wast` | All passed | 47 | 0 | 0 |
| `return_call_indirect.wast` | All passed | 79 | 0 | 0 |
| `return_call_ref.wast` | All passed | 51 | 0 | 0 |
| `skip-stack-guard-page.wast` | All passed | 11 | 0 | 0 |
| `stack.wast` | All passed | 7 | 0 | 0 |
| `start.wast` | All passed | 20 | 0 | 0 |
| `switch.wast` | All passed | 28 | 0 | 0 |
| `table.wast` | All passed | 46 | 0 | 0 |
| `table_get.wast` | All passed | 16 | 0 | 0 |
| `table_grow.wast` | All passed | 58 | 0 | 0 |
| `table_set.wast` | All passed | 26 | 0 | 0 |
| `table_size.wast` | All passed | 39 | 0 | 0 |
| `token.wast` | All passed | 61 | 0 | 0 |
| `type-canon.wast` | All passed | 2 | 0 | 0 |
| `type-equivalence.wast` | All passed | 32 | 0 | 0 |
| `type-rec.wast` | All passed | 27 | 0 | 0 |
| `type.wast` | All passed | 3 | 0 | 0 |
| `unreached-invalid.wast` | All passed | 121 | 0 | 0 |
| `unreached-valid.wast` | All passed | 13 | 0 | 0 |
| `unwind.wast` | All passed | 50 | 0 | 0 |
| `utf8-custom-section-id.wast` | All passed | 176 | 0 | 0 |
| `utf8-import-field.wast` | All passed | 176 | 0 | 0 |
| `utf8-import-module.wast` | All passed | 176 | 0 | 0 |
| `utf8-invalid-encoding.wast` | All passed | 176 | 0 | 0 |

## exceptions

| Suite | Result | Passed | Failed | Skipped |
|---|---|---:|---:|---:|
| `exceptions/tag.wast` | Has failures | 8 | 2 | 0 |
| `exceptions/throw.wast` | All passed | 13 | 0 | 0 |
| `exceptions/throw_ref.wast` | All passed | 15 | 0 | 0 |
| `exceptions/try_table.wast` | All passed | 62 | 0 | 0 |

## bulk-memory

| Suite | Result | Passed | Failed | Skipped |
|---|---|---:|---:|---:|
| `bulk-memory/bulk.wast` | All passed | 117 | 0 | 0 |
| `bulk-memory/memory_copy.wast` | All passed | 4450 | 0 | 0 |
| `bulk-memory/memory_fill.wast` | All passed | 100 | 0 | 0 |
| `bulk-memory/memory_init.wast` | All passed | 240 | 0 | 0 |
| `bulk-memory/table-sub.wast` | All passed | 3 | 0 | 0 |
| `bulk-memory/table_copy.wast` | All passed | 1728 | 0 | 0 |
| `bulk-memory/table_fill.wast` | All passed | 45 | 0 | 0 |
| `bulk-memory/table_init.wast` | All passed | 780 | 0 | 0 |

## multi-memory

| Suite | Result | Passed | Failed | Skipped |
|---|---|---:|---:|---:|
| `multi-memory/address0.wast` | All passed | 92 | 0 | 0 |
| `multi-memory/address1.wast` | All passed | 127 | 0 | 0 |
| `multi-memory/align0.wast` | All passed | 5 | 0 | 0 |
| `multi-memory/binary0.wast` | All passed | 7 | 0 | 0 |
| `multi-memory/data0.wast` | All passed | 7 | 0 | 0 |
| `multi-memory/data1.wast` | All passed | 14 | 0 | 0 |
| `multi-memory/data_drop0.wast` | Has failures | 0 | 11 | 0 |
| `multi-memory/exports0.wast` | All passed | 8 | 0 | 0 |
| `multi-memory/float_exprs0.wast` | All passed | 14 | 0 | 0 |
| `multi-memory/float_exprs1.wast` | All passed | 3 | 0 | 0 |
| `multi-memory/float_memory0.wast` | All passed | 30 | 0 | 0 |
| `multi-memory/imports0.wast` | All passed | 8 | 0 | 0 |
| `multi-memory/imports1.wast` | All passed | 5 | 0 | 0 |
| `multi-memory/imports2.wast` | All passed | 20 | 0 | 0 |
| `multi-memory/imports3.wast` | All passed | 10 | 0 | 0 |
| `multi-memory/imports4.wast` | All passed | 16 | 0 | 0 |
| `multi-memory/linking0.wast` | All passed | 6 | 0 | 0 |
| `multi-memory/linking1.wast` | All passed | 14 | 0 | 0 |
| `multi-memory/linking2.wast` | All passed | 11 | 0 | 0 |
| `multi-memory/linking3.wast` | All passed | 14 | 0 | 0 |
| `multi-memory/load0.wast` | All passed | 3 | 0 | 0 |
| `multi-memory/load1.wast` | All passed | 18 | 0 | 0 |
| `multi-memory/load2.wast` | All passed | 38 | 0 | 0 |
| `multi-memory/memory-multi.wast` | All passed | 6 | 0 | 0 |
| `multi-memory/memory_copy0.wast` | All passed | 29 | 0 | 0 |
| `multi-memory/memory_copy1.wast` | All passed | 14 | 0 | 0 |
| `multi-memory/memory_fill0.wast` | All passed | 16 | 0 | 0 |
| `multi-memory/memory_grow.wast` | All passed | 51 | 0 | 0 |
| `multi-memory/memory_init0.wast` | All passed | 13 | 0 | 0 |
| `multi-memory/memory_size0.wast` | All passed | 8 | 0 | 0 |
| `multi-memory/memory_size1.wast` | All passed | 15 | 0 | 0 |
| `multi-memory/memory_size2.wast` | All passed | 21 | 0 | 0 |
| `multi-memory/memory_size3.wast` | All passed | 2 | 0 | 0 |
| `multi-memory/memory_size_import.wast` | All passed | 7 | 0 | 0 |
| `multi-memory/memory_trap0.wast` | All passed | 14 | 0 | 0 |
| `multi-memory/memory_trap1.wast` | All passed | 168 | 0 | 0 |
| `multi-memory/start0.wast` | All passed | 9 | 0 | 0 |
| `multi-memory/store0.wast` | All passed | 5 | 0 | 0 |
| `multi-memory/store1.wast` | All passed | 13 | 0 | 0 |
| `multi-memory/store2.wast` | All passed | 25 | 0 | 0 |
| `multi-memory/traps0.wast` | All passed | 15 | 0 | 0 |

## memory64

| Suite | Result | Passed | Failed | Skipped |
|---|---|---:|---:|---:|
| `memory64/address64.wast` | Has failures | 0 | 242 | 0 |
| `memory64/align64.wast` | Has failures | 46 | 111 | 0 |
| `memory64/binary_leb128_64.wast` | Has failures | 0 | 2 | 0 |
| `memory64/bulk64.wast` | Has failures | 0 | 70 | 0 |
| `memory64/call_indirect64.wast` | Has failures | 0 | 2 | 0 |
| `memory64/endianness64.wast` | Has failures | 0 | 69 | 0 |
| `memory64/float_memory64.wast` | Has failures | 0 | 90 | 0 |
| `memory64/load64.wast` | Has failures | 13 | 84 | 0 |
| `memory64/memory64-imports.wast` | Has failures | 8 | 70 | 0 |
| `memory64/memory64.wast` | Has failures | 9 | 60 | 0 |
| `memory64/memory_copy64.wast` | Has failures | 3864 | 586 | 0 |
| `memory64/memory_fill64.wast` | Has failures | 1 | 99 | 0 |
| `memory64/memory_grow64.wast` | Has failures | 0 | 49 | 0 |
| `memory64/memory_init64.wast` | Has failures | 1 | 239 | 0 |
| `memory64/memory_redundancy64.wast` | Has failures | 0 | 8 | 0 |
| `memory64/memory_trap64.wast` | Has failures | 0 | 172 | 0 |
| `memory64/table64.wast` | Has failures | 0 | 14 | 0 |
| `memory64/table_copy64.wast` | Has failures | 1684 | 44 | 0 |
| `memory64/table_copy_mixed.wast` | Has failures | 0 | 4 | 0 |
| `memory64/table_fill64.wast` | Has failures | 9 | 71 | 0 |
| `memory64/table_get64.wast` | Has failures | 0 | 11 | 0 |
| `memory64/table_grow64.wast` | Has failures | 0 | 22 | 0 |
| `memory64/table_init64.wast` | Has failures | 780 | 96 | 0 |
| `memory64/table_set64.wast` | Has failures | 0 | 19 | 0 |
| `memory64/table_size64.wast` | Has failures | 0 | 37 | 0 |

## gc

| Suite | Result | Passed | Failed | Skipped |
|---|---|---:|---:|---:|
| `gc/array.wast` | Has failures | 0 | 46 | 8 |
| `gc/array_copy.wast` | Has failures | 0 | 35 | 0 |
| `gc/array_fill.wast` | Has failures | 0 | 17 | 0 |
| `gc/array_init_data.wast` | Has failures | 0 | 46 | 0 |
| `gc/array_init_elem.wast` | Has failures | 0 | 23 | 0 |
| `gc/array_new_data.wast` | Has failures | 0 | 24 | 4 |
| `gc/array_new_elem.wast` | Has failures | 0 | 14 | 8 |
| `gc/binary-gc.wast` | Has failures | 0 | 1 | 0 |
| `gc/br_on_cast.wast` | Has failures | 0 | 37 | 0 |
| `gc/br_on_cast_fail.wast` | Has failures | 0 | 37 | 0 |
| `gc/extern.wast` | Inconclusive | — | — | — |
| `gc/i31.wast` | Has failures | 2 | 70 | 1 |
| `gc/ref_cast.wast` | Has failures | 0 | 45 | 0 |
| `gc/ref_eq.wast` | Has failures | 0 | 89 | 0 |
| `gc/ref_test.wast` | Has failures | 0 | 71 | 0 |
| `gc/struct.wast` | Has failures | 4 | 25 | 1 |
| `gc/type-subtyping.wast` | Has failures | 0 | 117 | 0 |

## simd

| Suite | Result | Passed | Failed | Skipped |
|---|---|---:|---:|---:|
| `simd/simd_address.wast` | Has failures | 2 | 11 | 36 |
| `simd/simd_align.wast` | Has failures | 34 | 58 | 8 |
| `simd/simd_bit_shift.wast` | Has failures | 15 | 50 | 187 |
| `simd/simd_bitwise.wast` | Has failures | 0 | 43 | 126 |
| `simd/simd_boolean.wast` | Has failures | 4 | 14 | 259 |
| `simd/simd_const.wast` | Has failures | 302 | 253 | 203 |
| `simd/simd_conversions.wast` | Has failures | 30 | 20 | 232 |
| `simd/simd_f32x4.wast` | Has failures | 8 | 10 | 772 |
| `simd/simd_f32x4_arith.wast` | Has failures | 0 | 19 | 1803 |
| `simd/simd_f32x4_cmp.wast` | Has failures | 6 | 33 | 2568 |
| `simd/simd_f32x4_pmin_pmax.wast` | Has failures | 8 | 7 | 3872 |
| `simd/simd_f32x4_rounding.wast` | Has failures | 16 | 9 | 176 |
| `simd/simd_f64x2.wast` | Has failures | 0 | 10 | 793 |
| `simd/simd_f64x2_arith.wast` | Has failures | 0 | 19 | 1806 |
| `simd/simd_f64x2_cmp.wast` | Has failures | 6 | 33 | 2646 |
| `simd/simd_f64x2_pmin_pmax.wast` | Has failures | 8 | 7 | 3872 |
| `simd/simd_f64x2_rounding.wast` | Has failures | 16 | 9 | 176 |
| `simd/simd_i16x8_arith.wast` | Has failures | 0 | 13 | 181 |
| `simd/simd_i16x8_arith2.wast` | Has failures | 2 | 19 | 151 |
| `simd/simd_i16x8_cmp.wast` | Has failures | 0 | 45 | 420 |
| `simd/simd_i16x8_extadd_pairwise_i8x16.wast` | Has failures | 0 | 5 | 16 |
| `simd/simd_i16x8_extmul_i8x16.wast` | Has failures | 0 | 13 | 104 |
| `simd/simd_i16x8_q15mulr_sat_s.wast` | Has failures | 0 | 4 | 26 |
| `simd/simd_i16x8_sat_arith.wast` | Has failures | 4 | 14 | 204 |
| `simd/simd_i32x4_arith.wast` | Has failures | 0 | 13 | 181 |
| `simd/simd_i32x4_arith2.wast` | Has failures | 12 | 16 | 121 |
| `simd/simd_i32x4_cmp.wast` | Has failures | 10 | 45 | 420 |
| `simd/simd_i32x4_dot_i16x8.wast` | Has failures | 0 | 4 | 28 |
| `simd/simd_i32x4_extadd_pairwise_i16x8.wast` | Has failures | 0 | 5 | 16 |
| `simd/simd_i32x4_extmul_i16x8.wast` | Has failures | 0 | 13 | 104 |
| `simd/simd_i32x4_trunc_sat_f32x4.wast` | Has failures | 0 | 5 | 102 |
| `simd/simd_i32x4_trunc_sat_f64x2.wast` | Has failures | 0 | 5 | 102 |
| `simd/simd_i64x2_arith.wast` | Has failures | 0 | 13 | 187 |
| `simd/simd_i64x2_arith2.wast` | Has failures | 0 | 4 | 21 |
| `simd/simd_i64x2_cmp.wast` | Has failures | 0 | 11 | 102 |
| `simd/simd_i64x2_extmul_i32x4.wast` | Has failures | 0 | 13 | 104 |
| `simd/simd_i8x16_arith.wast` | Has failures | 0 | 10 | 121 |
| `simd/simd_i8x16_arith2.wast` | Has failures | 6 | 21 | 184 |
| `simd/simd_i8x16_cmp.wast` | Has failures | 0 | 45 | 400 |
| `simd/simd_i8x16_sat_arith.wast` | Has failures | 12 | 14 | 188 |
| `simd/simd_int_to_int_extend.wast` | Has failures | 0 | 25 | 228 |
| `simd/simd_lane.wast` | Has failures | 106 | 95 | 274 |
| `simd/simd_linking.wast` | Has failures | 0 | 3 | 0 |
| `simd/simd_load.wast` | Has failures | 3 | 21 | 15 |
| `simd/simd_load16_lane.wast` | Has failures | 0 | 4 | 32 |
| `simd/simd_load32_lane.wast` | Has failures | 0 | 4 | 20 |
| `simd/simd_load64_lane.wast` | Has failures | 0 | 4 | 12 |
| `simd/simd_load8_lane.wast` | Has failures | 0 | 4 | 48 |
| `simd/simd_load_extend.wast` | Has failures | 6 | 32 | 66 |
| `simd/simd_load_splat.wast` | Has failures | 4 | 46 | 76 |
| `simd/simd_load_zero.wast` | Has failures | 6 | 12 | 21 |
| `simd/simd_memory-multi.wast` | Has failures | 0 | 1 | 0 |
| `simd/simd_select.wast` | Has failures | 0 | 1 | 6 |
| `simd/simd_splat.wast` | Has failures | 1 | 42 | 142 |
| `simd/simd_store.wast` | Has failures | 3 | 17 | 8 |
| `simd/simd_store16_lane.wast` | Has failures | 0 | 4 | 32 |
| `simd/simd_store32_lane.wast` | Has failures | 0 | 4 | 20 |
| `simd/simd_store64_lane.wast` | Has failures | 0 | 4 | 12 |
| `simd/simd_store8_lane.wast` | Has failures | 0 | 4 | 48 |

## relaxed-simd

| Suite | Result | Passed | Failed | Skipped |
|---|---|---:|---:|---:|
| `relaxed-simd/i16x8_relaxed_q15mulr_s.wast` | Has failures | 0 | 1 | 2 |
| `relaxed-simd/i32x4_relaxed_trunc.wast` | Has failures | 0 | 1 | 0 |
| `relaxed-simd/i8x16_relaxed_swizzle.wast` | Has failures | 0 | 1 | 5 |
| `relaxed-simd/relaxed_dot_product.wast` | Has failures | 0 | 1 | 10 |
| `relaxed-simd/relaxed_laneselect.wast` | Has failures | 0 | 1 | 11 |
| `relaxed-simd/relaxed_madd_nmadd.wast` | Has failures | 0 | 2 | 17 |
| `relaxed-simd/relaxed_min_max.wast` | Has failures | 0 | 1 | 24 |
