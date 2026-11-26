# Wardite と WebAssembly wg-3.0 のスイート対応表

[English](wg-3.0-suite-coverage.md)

Wardite `9e1d31a` で、公式の `test/core` 以下にある全258本の `.wast` を実行した。直下97本は21,228件すべて成功した。例外4本は98件成功、2件失敗。失敗した `exceptions/tag.wast` の49行目と60行目では、リンク時の拒否は期待どおりだが、期待する診断 `incompatible import` に対して Wardite は `incompatible import type` を返した。[公式テスト（固定リビジョン）](https://github.com/WebAssembly/spec/tree/9d36019973201a19f9c9ebb0f10828b2fe2374aa/test/core)

| 分類 | 本数 | 全件成功 | 一部スキップ・失敗0 | 失敗あり | 判定保留 |
|---|---:|---:|---:|---:|---:|
| 基本37本 | 37 | 37 | 0 | 0 | 0 |
| 直下のその他 | 60 | 60 | 0 | 0 | 0 |
| exceptions | 4 | 3 | 0 | 1 | 0 |
| bulk-memory | 8 | 6 | 0 | 2 | 0 |
| multi-memory | 41 | 40 | 0 | 1 | 0 |
| memory64 | 25 | 0 | 0 | 25 | 0 |
| gc | 17 | 0 | 0 | 16 | 1 |
| simd | 59 | 0 | 0 | 59 | 0 |
| relaxed-simd | 7 | 0 | 0 | 7 | 0 |
| 合計 | 258 | 146 | 0 | 111 | 1 |

各ファイルを1スイートとして数えた。成功件数にはモジュールのロード、呼び出し、無効なモジュールの拒否、テキスト構文の検査を含む。ロードに失敗し、後続の呼び出しも失敗した場合は、それぞれを1件と数える。

Spinel 7289・Efflorescence（JIT 無効）、wasm-tools 1.236.0、WABT 1.0.42 を使用した。固定版の `test/core` を `SPEC_CORE_DIR` に指定し、各ファイルを個別の一時ディレクトリとワーカープロセスで `CoreSpec.run` に渡した。各スイート内のコマンドは記述順に実行した。

`gc/extern.wast` はランナーが参照値の期待値を読み取る際に `KeyError` で中断したため、判定保留とした。

## 基本37本

| スイート | 判定 | 成功 | 失敗 | スキップ |
|---|---|---:|---:|---:|
| `address.wast` | 全件成功 | 260 | 0 | 0 |
| `align.wast` | 全件成功 | 165 | 0 | 0 |
| `block.wast` | 全件成功 | 223 | 0 | 0 |
| `br.wast` | 全件成功 | 97 | 0 | 0 |
| `br_if.wast` | 全件成功 | 119 | 0 | 0 |
| `br_table.wast` | 全件成功 | 186 | 0 | 0 |
| `call.wast` | 全件成功 | 91 | 0 | 0 |
| `call_indirect.wast` | 全件成功 | 172 | 0 | 0 |
| `conversions.wast` | 全件成功 | 619 | 0 | 0 |
| `endianness.wast` | 全件成功 | 69 | 0 | 0 |
| `f32.wast` | 全件成功 | 2514 | 0 | 0 |
| `f32_bitwise.wast` | 全件成功 | 364 | 0 | 0 |
| `f32_cmp.wast` | 全件成功 | 2407 | 0 | 0 |
| `f64.wast` | 全件成功 | 2514 | 0 | 0 |
| `f64_bitwise.wast` | 全件成功 | 364 | 0 | 0 |
| `f64_cmp.wast` | 全件成功 | 2407 | 0 | 0 |
| `float_memory.wast` | 全件成功 | 90 | 0 | 0 |
| `float_misc.wast` | 全件成功 | 471 | 0 | 0 |
| `global.wast` | 全件成功 | 124 | 0 | 0 |
| `i32.wast` | 全件成功 | 460 | 0 | 0 |
| `i64.wast` | 全件成功 | 416 | 0 | 0 |
| `if.wast` | 全件成功 | 241 | 0 | 0 |
| `int_exprs.wast` | 全件成功 | 108 | 0 | 0 |
| `load.wast` | 全件成功 | 97 | 0 | 0 |
| `local_get.wast` | 全件成功 | 36 | 0 | 0 |
| `local_set.wast` | 全件成功 | 53 | 0 | 0 |
| `local_tee.wast` | 全件成功 | 98 | 0 | 0 |
| `loop.wast` | 全件成功 | 120 | 0 | 0 |
| `memory_grow.wast` | 全件成功 | 106 | 0 | 0 |
| `memory_size.wast` | 全件成功 | 42 | 0 | 0 |
| `memory_trap.wast` | 全件成功 | 182 | 0 | 0 |
| `nop.wast` | 全件成功 | 88 | 0 | 0 |
| `return.wast` | 全件成功 | 84 | 0 | 0 |
| `select.wast` | 全件成功 | 157 | 0 | 0 |
| `store.wast` | 全件成功 | 68 | 0 | 0 |
| `traps.wast` | 全件成功 | 36 | 0 | 0 |
| `unreachable.wast` | 全件成功 | 64 | 0 | 0 |

## 直下のその他

| スイート | 判定 | 成功 | 失敗 | スキップ |
|---|---|---:|---:|---:|
| `annotations.wast` | 全件成功 | 74 | 0 | 0 |
| `binary-leb128.wast` | 全件成功 | 91 | 0 | 0 |
| `binary.wast` | 全件成功 | 127 | 0 | 0 |
| `br_on_non_null.wast` | 全件成功 | 12 | 0 | 0 |
| `br_on_null.wast` | 全件成功 | 10 | 0 | 0 |
| `call_ref.wast` | 全件成功 | 35 | 0 | 0 |
| `comments.wast` | 全件成功 | 8 | 0 | 0 |
| `const.wast` | 全件成功 | 778 | 0 | 0 |
| `custom.wast` | 全件成功 | 11 | 0 | 0 |
| `data.wast` | 全件成功 | 65 | 0 | 0 |
| `elem.wast` | 全件成功 | 151 | 0 | 0 |
| `exports.wast` | 全件成功 | 97 | 0 | 0 |
| `fac.wast` | 全件成功 | 8 | 0 | 0 |
| `float_exprs.wast` | 全件成功 | 927 | 0 | 0 |
| `float_literals.wast` | 全件成功 | 179 | 0 | 0 |
| `forward.wast` | 全件成功 | 5 | 0 | 0 |
| `func.wast` | 全件成功 | 175 | 0 | 0 |
| `func_ptrs.wast` | 全件成功 | 36 | 0 | 0 |
| `id.wast` | 全件成功 | 7 | 0 | 0 |
| `imports.wast` | 全件成功 | 218 | 0 | 0 |
| `inline-module.wast` | 全件成功 | 1 | 0 | 0 |
| `instance.wast` | 全件成功 | 23 | 0 | 0 |
| `int_literals.wast` | 全件成功 | 51 | 0 | 0 |
| `labels.wast` | 全件成功 | 29 | 0 | 0 |
| `left-to-right.wast` | 全件成功 | 96 | 0 | 0 |
| `linking.wast` | 全件成功 | 163 | 0 | 0 |
| `local_init.wast` | 全件成功 | 10 | 0 | 0 |
| `memory.wast` | 全件成功 | 90 | 0 | 0 |
| `memory_redundancy.wast` | 全件成功 | 8 | 0 | 0 |
| `names.wast` | 全件成功 | 486 | 0 | 0 |
| `obsolete-keywords.wast` | 全件成功 | 11 | 0 | 0 |
| `ref.wast` | 全件成功 | 13 | 0 | 0 |
| `ref_as_non_null.wast` | 全件成功 | 7 | 0 | 0 |
| `ref_func.wast` | 全件成功 | 17 | 0 | 0 |
| `ref_is_null.wast` | 全件成功 | 22 | 0 | 0 |
| `ref_null.wast` | 全件成功 | 34 | 0 | 0 |
| `return_call.wast` | 全件成功 | 47 | 0 | 0 |
| `return_call_indirect.wast` | 全件成功 | 79 | 0 | 0 |
| `return_call_ref.wast` | 全件成功 | 51 | 0 | 0 |
| `skip-stack-guard-page.wast` | 全件成功 | 11 | 0 | 0 |
| `stack.wast` | 全件成功 | 7 | 0 | 0 |
| `start.wast` | 全件成功 | 20 | 0 | 0 |
| `switch.wast` | 全件成功 | 28 | 0 | 0 |
| `table.wast` | 全件成功 | 46 | 0 | 0 |
| `table_get.wast` | 全件成功 | 16 | 0 | 0 |
| `table_grow.wast` | 全件成功 | 58 | 0 | 0 |
| `table_set.wast` | 全件成功 | 26 | 0 | 0 |
| `table_size.wast` | 全件成功 | 39 | 0 | 0 |
| `token.wast` | 全件成功 | 61 | 0 | 0 |
| `type-canon.wast` | 全件成功 | 2 | 0 | 0 |
| `type-equivalence.wast` | 全件成功 | 32 | 0 | 0 |
| `type-rec.wast` | 全件成功 | 27 | 0 | 0 |
| `type.wast` | 全件成功 | 3 | 0 | 0 |
| `unreached-invalid.wast` | 全件成功 | 121 | 0 | 0 |
| `unreached-valid.wast` | 全件成功 | 13 | 0 | 0 |
| `unwind.wast` | 全件成功 | 50 | 0 | 0 |
| `utf8-custom-section-id.wast` | 全件成功 | 176 | 0 | 0 |
| `utf8-import-field.wast` | 全件成功 | 176 | 0 | 0 |
| `utf8-import-module.wast` | 全件成功 | 176 | 0 | 0 |
| `utf8-invalid-encoding.wast` | 全件成功 | 176 | 0 | 0 |

## exceptions

| スイート | 判定 | 成功 | 失敗 | スキップ |
|---|---|---:|---:|---:|
| `exceptions/tag.wast` | 失敗あり | 8 | 2 | 0 |
| `exceptions/throw.wast` | 全件成功 | 13 | 0 | 0 |
| `exceptions/throw_ref.wast` | 全件成功 | 15 | 0 | 0 |
| `exceptions/try_table.wast` | 全件成功 | 62 | 0 | 0 |

## bulk-memory

| スイート | 判定 | 成功 | 失敗 | スキップ |
|---|---|---:|---:|---:|
| `bulk-memory/bulk.wast` | 失敗あり | 104 | 13 | 0 |
| `bulk-memory/memory_copy.wast` | 全件成功 | 4450 | 0 | 0 |
| `bulk-memory/memory_fill.wast` | 全件成功 | 100 | 0 | 0 |
| `bulk-memory/memory_init.wast` | 失敗あり | 202 | 38 | 0 |
| `bulk-memory/table-sub.wast` | 全件成功 | 3 | 0 | 0 |
| `bulk-memory/table_copy.wast` | 全件成功 | 1728 | 0 | 0 |
| `bulk-memory/table_fill.wast` | 全件成功 | 45 | 0 | 0 |
| `bulk-memory/table_init.wast` | 全件成功 | 780 | 0 | 0 |

## multi-memory

| スイート | 判定 | 成功 | 失敗 | スキップ |
|---|---|---:|---:|---:|
| `multi-memory/address0.wast` | 全件成功 | 92 | 0 | 0 |
| `multi-memory/address1.wast` | 全件成功 | 127 | 0 | 0 |
| `multi-memory/align0.wast` | 全件成功 | 5 | 0 | 0 |
| `multi-memory/binary0.wast` | 全件成功 | 7 | 0 | 0 |
| `multi-memory/data0.wast` | 全件成功 | 7 | 0 | 0 |
| `multi-memory/data1.wast` | 全件成功 | 14 | 0 | 0 |
| `multi-memory/data_drop0.wast` | 失敗あり | 0 | 11 | 0 |
| `multi-memory/exports0.wast` | 全件成功 | 8 | 0 | 0 |
| `multi-memory/float_exprs0.wast` | 全件成功 | 14 | 0 | 0 |
| `multi-memory/float_exprs1.wast` | 全件成功 | 3 | 0 | 0 |
| `multi-memory/float_memory0.wast` | 全件成功 | 30 | 0 | 0 |
| `multi-memory/imports0.wast` | 全件成功 | 8 | 0 | 0 |
| `multi-memory/imports1.wast` | 全件成功 | 5 | 0 | 0 |
| `multi-memory/imports2.wast` | 全件成功 | 20 | 0 | 0 |
| `multi-memory/imports3.wast` | 全件成功 | 10 | 0 | 0 |
| `multi-memory/imports4.wast` | 全件成功 | 16 | 0 | 0 |
| `multi-memory/linking0.wast` | 全件成功 | 6 | 0 | 0 |
| `multi-memory/linking1.wast` | 全件成功 | 14 | 0 | 0 |
| `multi-memory/linking2.wast` | 全件成功 | 11 | 0 | 0 |
| `multi-memory/linking3.wast` | 全件成功 | 14 | 0 | 0 |
| `multi-memory/load0.wast` | 全件成功 | 3 | 0 | 0 |
| `multi-memory/load1.wast` | 全件成功 | 18 | 0 | 0 |
| `multi-memory/load2.wast` | 全件成功 | 38 | 0 | 0 |
| `multi-memory/memory-multi.wast` | 全件成功 | 6 | 0 | 0 |
| `multi-memory/memory_copy0.wast` | 全件成功 | 29 | 0 | 0 |
| `multi-memory/memory_copy1.wast` | 全件成功 | 14 | 0 | 0 |
| `multi-memory/memory_fill0.wast` | 全件成功 | 16 | 0 | 0 |
| `multi-memory/memory_grow.wast` | 全件成功 | 51 | 0 | 0 |
| `multi-memory/memory_init0.wast` | 全件成功 | 13 | 0 | 0 |
| `multi-memory/memory_size0.wast` | 全件成功 | 8 | 0 | 0 |
| `multi-memory/memory_size1.wast` | 全件成功 | 15 | 0 | 0 |
| `multi-memory/memory_size2.wast` | 全件成功 | 21 | 0 | 0 |
| `multi-memory/memory_size3.wast` | 全件成功 | 2 | 0 | 0 |
| `multi-memory/memory_size_import.wast` | 全件成功 | 7 | 0 | 0 |
| `multi-memory/memory_trap0.wast` | 全件成功 | 14 | 0 | 0 |
| `multi-memory/memory_trap1.wast` | 全件成功 | 168 | 0 | 0 |
| `multi-memory/start0.wast` | 全件成功 | 9 | 0 | 0 |
| `multi-memory/store0.wast` | 全件成功 | 5 | 0 | 0 |
| `multi-memory/store1.wast` | 全件成功 | 13 | 0 | 0 |
| `multi-memory/store2.wast` | 全件成功 | 25 | 0 | 0 |
| `multi-memory/traps0.wast` | 全件成功 | 15 | 0 | 0 |

## memory64

| スイート | 判定 | 成功 | 失敗 | スキップ |
|---|---|---:|---:|---:|
| `memory64/address64.wast` | 失敗あり | 0 | 242 | 0 |
| `memory64/align64.wast` | 失敗あり | 46 | 111 | 0 |
| `memory64/binary_leb128_64.wast` | 失敗あり | 0 | 2 | 0 |
| `memory64/bulk64.wast` | 失敗あり | 0 | 70 | 0 |
| `memory64/call_indirect64.wast` | 失敗あり | 0 | 2 | 0 |
| `memory64/endianness64.wast` | 失敗あり | 0 | 69 | 0 |
| `memory64/float_memory64.wast` | 失敗あり | 0 | 90 | 0 |
| `memory64/load64.wast` | 失敗あり | 13 | 84 | 0 |
| `memory64/memory64-imports.wast` | 失敗あり | 8 | 70 | 0 |
| `memory64/memory64.wast` | 失敗あり | 9 | 60 | 0 |
| `memory64/memory_copy64.wast` | 失敗あり | 3864 | 586 | 0 |
| `memory64/memory_fill64.wast` | 失敗あり | 1 | 99 | 0 |
| `memory64/memory_grow64.wast` | 失敗あり | 0 | 49 | 0 |
| `memory64/memory_init64.wast` | 失敗あり | 1 | 239 | 0 |
| `memory64/memory_redundancy64.wast` | 失敗あり | 0 | 8 | 0 |
| `memory64/memory_trap64.wast` | 失敗あり | 0 | 172 | 0 |
| `memory64/table64.wast` | 失敗あり | 0 | 14 | 0 |
| `memory64/table_copy64.wast` | 失敗あり | 1684 | 44 | 0 |
| `memory64/table_copy_mixed.wast` | 失敗あり | 0 | 4 | 0 |
| `memory64/table_fill64.wast` | 失敗あり | 9 | 71 | 0 |
| `memory64/table_get64.wast` | 失敗あり | 0 | 11 | 0 |
| `memory64/table_grow64.wast` | 失敗あり | 0 | 22 | 0 |
| `memory64/table_init64.wast` | 失敗あり | 780 | 96 | 0 |
| `memory64/table_set64.wast` | 失敗あり | 0 | 19 | 0 |
| `memory64/table_size64.wast` | 失敗あり | 0 | 37 | 0 |

## gc

| スイート | 判定 | 成功 | 失敗 | スキップ |
|---|---|---:|---:|---:|
| `gc/array.wast` | 失敗あり | 0 | 46 | 8 |
| `gc/array_copy.wast` | 失敗あり | 0 | 35 | 0 |
| `gc/array_fill.wast` | 失敗あり | 0 | 17 | 0 |
| `gc/array_init_data.wast` | 失敗あり | 0 | 46 | 0 |
| `gc/array_init_elem.wast` | 失敗あり | 0 | 23 | 0 |
| `gc/array_new_data.wast` | 失敗あり | 0 | 24 | 4 |
| `gc/array_new_elem.wast` | 失敗あり | 0 | 14 | 8 |
| `gc/binary-gc.wast` | 失敗あり | 0 | 1 | 0 |
| `gc/br_on_cast.wast` | 失敗あり | 0 | 37 | 0 |
| `gc/br_on_cast_fail.wast` | 失敗あり | 0 | 37 | 0 |
| `gc/extern.wast` | 判定保留 | — | — | — |
| `gc/i31.wast` | 失敗あり | 2 | 70 | 1 |
| `gc/ref_cast.wast` | 失敗あり | 0 | 45 | 0 |
| `gc/ref_eq.wast` | 失敗あり | 0 | 89 | 0 |
| `gc/ref_test.wast` | 失敗あり | 0 | 71 | 0 |
| `gc/struct.wast` | 失敗あり | 4 | 25 | 1 |
| `gc/type-subtyping.wast` | 失敗あり | 0 | 117 | 0 |

## simd

| スイート | 判定 | 成功 | 失敗 | スキップ |
|---|---|---:|---:|---:|
| `simd/simd_address.wast` | 失敗あり | 2 | 11 | 36 |
| `simd/simd_align.wast` | 失敗あり | 34 | 58 | 8 |
| `simd/simd_bit_shift.wast` | 失敗あり | 15 | 50 | 187 |
| `simd/simd_bitwise.wast` | 失敗あり | 0 | 43 | 126 |
| `simd/simd_boolean.wast` | 失敗あり | 4 | 14 | 259 |
| `simd/simd_const.wast` | 失敗あり | 302 | 253 | 203 |
| `simd/simd_conversions.wast` | 失敗あり | 30 | 20 | 232 |
| `simd/simd_f32x4.wast` | 失敗あり | 8 | 10 | 772 |
| `simd/simd_f32x4_arith.wast` | 失敗あり | 0 | 19 | 1803 |
| `simd/simd_f32x4_cmp.wast` | 失敗あり | 6 | 33 | 2568 |
| `simd/simd_f32x4_pmin_pmax.wast` | 失敗あり | 8 | 7 | 3872 |
| `simd/simd_f32x4_rounding.wast` | 失敗あり | 16 | 9 | 176 |
| `simd/simd_f64x2.wast` | 失敗あり | 0 | 10 | 793 |
| `simd/simd_f64x2_arith.wast` | 失敗あり | 0 | 19 | 1806 |
| `simd/simd_f64x2_cmp.wast` | 失敗あり | 6 | 33 | 2646 |
| `simd/simd_f64x2_pmin_pmax.wast` | 失敗あり | 8 | 7 | 3872 |
| `simd/simd_f64x2_rounding.wast` | 失敗あり | 16 | 9 | 176 |
| `simd/simd_i16x8_arith.wast` | 失敗あり | 0 | 13 | 181 |
| `simd/simd_i16x8_arith2.wast` | 失敗あり | 2 | 19 | 151 |
| `simd/simd_i16x8_cmp.wast` | 失敗あり | 0 | 45 | 420 |
| `simd/simd_i16x8_extadd_pairwise_i8x16.wast` | 失敗あり | 0 | 5 | 16 |
| `simd/simd_i16x8_extmul_i8x16.wast` | 失敗あり | 0 | 13 | 104 |
| `simd/simd_i16x8_q15mulr_sat_s.wast` | 失敗あり | 0 | 4 | 26 |
| `simd/simd_i16x8_sat_arith.wast` | 失敗あり | 4 | 14 | 204 |
| `simd/simd_i32x4_arith.wast` | 失敗あり | 0 | 13 | 181 |
| `simd/simd_i32x4_arith2.wast` | 失敗あり | 12 | 16 | 121 |
| `simd/simd_i32x4_cmp.wast` | 失敗あり | 10 | 45 | 420 |
| `simd/simd_i32x4_dot_i16x8.wast` | 失敗あり | 0 | 4 | 28 |
| `simd/simd_i32x4_extadd_pairwise_i16x8.wast` | 失敗あり | 0 | 5 | 16 |
| `simd/simd_i32x4_extmul_i16x8.wast` | 失敗あり | 0 | 13 | 104 |
| `simd/simd_i32x4_trunc_sat_f32x4.wast` | 失敗あり | 0 | 5 | 102 |
| `simd/simd_i32x4_trunc_sat_f64x2.wast` | 失敗あり | 0 | 5 | 102 |
| `simd/simd_i64x2_arith.wast` | 失敗あり | 0 | 13 | 187 |
| `simd/simd_i64x2_arith2.wast` | 失敗あり | 0 | 4 | 21 |
| `simd/simd_i64x2_cmp.wast` | 失敗あり | 0 | 11 | 102 |
| `simd/simd_i64x2_extmul_i32x4.wast` | 失敗あり | 0 | 13 | 104 |
| `simd/simd_i8x16_arith.wast` | 失敗あり | 0 | 10 | 121 |
| `simd/simd_i8x16_arith2.wast` | 失敗あり | 6 | 21 | 184 |
| `simd/simd_i8x16_cmp.wast` | 失敗あり | 0 | 45 | 400 |
| `simd/simd_i8x16_sat_arith.wast` | 失敗あり | 12 | 14 | 188 |
| `simd/simd_int_to_int_extend.wast` | 失敗あり | 0 | 25 | 228 |
| `simd/simd_lane.wast` | 失敗あり | 106 | 95 | 274 |
| `simd/simd_linking.wast` | 失敗あり | 0 | 3 | 0 |
| `simd/simd_load.wast` | 失敗あり | 3 | 21 | 15 |
| `simd/simd_load16_lane.wast` | 失敗あり | 0 | 4 | 32 |
| `simd/simd_load32_lane.wast` | 失敗あり | 0 | 4 | 20 |
| `simd/simd_load64_lane.wast` | 失敗あり | 0 | 4 | 12 |
| `simd/simd_load8_lane.wast` | 失敗あり | 0 | 4 | 48 |
| `simd/simd_load_extend.wast` | 失敗あり | 6 | 32 | 66 |
| `simd/simd_load_splat.wast` | 失敗あり | 4 | 46 | 76 |
| `simd/simd_load_zero.wast` | 失敗あり | 6 | 12 | 21 |
| `simd/simd_memory-multi.wast` | 失敗あり | 0 | 1 | 0 |
| `simd/simd_select.wast` | 失敗あり | 0 | 1 | 6 |
| `simd/simd_splat.wast` | 失敗あり | 1 | 42 | 142 |
| `simd/simd_store.wast` | 失敗あり | 3 | 17 | 8 |
| `simd/simd_store16_lane.wast` | 失敗あり | 0 | 4 | 32 |
| `simd/simd_store32_lane.wast` | 失敗あり | 0 | 4 | 20 |
| `simd/simd_store64_lane.wast` | 失敗あり | 0 | 4 | 12 |
| `simd/simd_store8_lane.wast` | 失敗あり | 0 | 4 | 48 |

## relaxed-simd

| スイート | 判定 | 成功 | 失敗 | スキップ |
|---|---|---:|---:|---:|
| `relaxed-simd/i16x8_relaxed_q15mulr_s.wast` | 失敗あり | 0 | 1 | 2 |
| `relaxed-simd/i32x4_relaxed_trunc.wast` | 失敗あり | 0 | 1 | 0 |
| `relaxed-simd/i8x16_relaxed_swizzle.wast` | 失敗あり | 0 | 1 | 5 |
| `relaxed-simd/relaxed_dot_product.wast` | 失敗あり | 0 | 1 | 10 |
| `relaxed-simd/relaxed_laneselect.wast` | 失敗あり | 0 | 1 | 11 |
| `relaxed-simd/relaxed_madd_nmadd.wast` | 失敗あり | 0 | 2 | 17 |
| `relaxed-simd/relaxed_min_max.wast` | 失敗あり | 0 | 1 | 24 |
