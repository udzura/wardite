# Efflorescence M0: 既存VMの命令対応範囲

調査日: 2026-11-05。基準コミット: `5534486`。
実行コードは変更せず、デコーダー、Runtime、生成済みEvaluator、Translatorを照合した。
既存の `benchmark/compare.rb` の作業中の変更は対象外。

現在は M1 の28命令・新形式 EH、M2 の15命令、M3 の `call_indirect` を実装済み。
M0 の188命令のうち、既存21 + M1追加28 + M2追加15 + M3追加1 = **65命令**に対応する
（新形式 EH 3命令は別枠）。詳細は [M1](efflorescence-m1.md)、[M2](efflorescence-m2.md)、[M3](efflorescence-m3.md) の実装記録を参照。

| M2の追加分類 | 命令数 | 現在の状態 |
|---|---:|---|
| i32 load / store | 8 | 全幅・符号・境界検査に対応 |
| i32 global.get/set | 2 | snapshot・mutable検査・Storeとの共有に対応 |
| size/grow/init/copy/fill | 5 | 上限・実行時segment・範囲事前検査に対応 |

以下の188命令の集計・一覧はM0時点の記録である。

## 後続の設計

[M1の制御構造と新形式EHのADR](adr/0001-efflorescence-m1-control-and-eh.md)で、M1内部の実装順と受け入れ条件を定義する。
ADRは本調査の既存VM同等対応に加え、Efflorescence限定の新形式EHと必要な複数結果blockを追加する設計である。
以下の188命令の集計・対象外一覧は調査時点の旧VMを基準とした記録として維持する。

## 結論と集計の意味

- 既存VMにデコードから実行ハンドラまでの経路がある命令: **188個**。
- EfflorescenceのTranslatorが受け付ける命令: **21個**。i32のみ・関数結果最大1個・importなし等の制約付き。
- 新規対応が必要な命令: **167個**。既存21命令にも型や呼び出し対象の拡張が必要。
- 命令表に名前があるが既存VMの実行ハンドラがないもの: **22個**。今回の同等対応から除外。
- 生成済みだが命令表から到達しないハンドラ: **4個**。今回の集計から除外。

188個は「実装経路あり」の静的集計であり、全命令の正常系・境界値・trapの実行確認済み件数ではない。
既存VMの振る舞いを無条件に正解とはしない。下記の個別確認で既存の問題も見つかった。

| 既存ディスパッチの分類 | 命令数 |
|---|---:|
| 制御・変数・memory管理等 | 25 |
| i32 ALU・メモリアクセス・定数 | 38 |
| i64 ALU・メモリアクセス・定数 | 41 |
| f32 ALU・メモリアクセス・定数 | 23 |
| f64 ALU・メモリアクセス・定数 | 23 |
| 型変換・符号拡張・飽和変換 | 38 |

新規命令の担当段階別内訳（既存命令の型拡張やimport等の統合要件は別途）:

| 段階 | 新規命令数 |
|---|---:|
| M1: i32・制御 | 28 |
| M2: i32メモリ・global・memory管理 | 15 |
| M3: call_indirect | 1 |
| M4: i64・整数間変換 | 47 |
| M5: float・floatを含む変換 | 76 |
| 合計 | 167 |

## スコープの制約

- `block/loop/if` のデコードは1バイトのblock type。型インデックスを使うシグネチャ、loop引数、multi-value blockを正式な同等対応要件にしない。
- 関数の複数結果は内部にarity処理があるが、公開呼び出しは2結果以上を `NotImplementedError` で拒否する。multi-value全体は別スコープ。
- 既存 `Runtime#call` のRuby引数はi32のみ。i64/f32/f64はWasm内部で使えることと、Ruby APIで直接引数を渡せることを区別する。テストには引数なしのWasmラッパーを利用できる。
- メモリ命令の実行対象は基本的にmemory 0。multi-memory/memory64を追加要件にしない。
- `call_indirect` はtable 0に固定。table/elementの初期化はあるが、table操作命令一式が実装されているわけではない。
- import、ホスト関数、WASI、start、data/element初期化、exportは命令数とは別の統合要件。Efflorescenceはstart実行を既に持つが、importはInstanceとTranslatorで拒否する。
- Spinelでは共有ローダーがWASIを拒否する。WASI検証はCRubyに限定し、Spinel対応拡大は別スコープ。
- Efflorescenceの既存21命令も、non-i32のlocal/select/分岐結果/関数引数・結果等への拡張を各型の段階で行う。`call` のホスト対応はM3。

## 命令一覧

`既存` はEfflorescenceの現在の制約内で対応済み。M1〜M5は提案する担当段階。
「テスト記載」は既存VM側の `test/**/*.rb`（Efflorescence名のファイルを除外）に命令名が現れるファイル。
これはテキスト検索による入口であり、実行カバレッジやassertの十分性を保証しない。`—` も未テストの断定ではない。
命令表記はWAT表記（内部の `i32_lts` 等は `i32.lt_s` に変換）。

### default

| opcode | 命令 | Efflorescence対応段階 | 既存VMテスト記載 |
|---|---|---|---|
| `00` | `unreachable` | 既存 | — |
| `01` | `nop` | 既存 | — |
| `02` | `block` | 既存 | [e2e/basic_test.rb](../test/e2e/basic_test.rb)<br>[e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `03` | `loop` | 既存 | [e2e/basic_test.rb](../test/e2e/basic_test.rb)<br>[e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `04` | `if` | M1 | [e2e/basic_test.rb](../test/e2e/basic_test.rb)<br>[e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `05` | `else` | M1 | [e2e/basic_test.rb](../test/e2e/basic_test.rb)<br>[e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `0b` | `end` | 既存 | [e2e/basic_test.rb](../test/e2e/basic_test.rb)<br>[e2e/spinel_test.rb](../test/e2e/spinel_test.rb)<br>[e2e/wasi_test.rb](../test/e2e/wasi_test.rb)<br>[import_test.rb](../test/import_test.rb)<br>[leb128_test.rb](../test/leb128_test.rb)<br>[spinel/sleb128.rb](../test/spinel/sleb128.rb)<br>[test_helper.rb](../test/test_helper.rb)<br>[value_test.rb](../test/value_test.rb)<br>[wardite_test.rb](../test/wardite_test.rb) |
| `0c` | `br` | 既存 | [e2e/basic_test.rb](../test/e2e/basic_test.rb) |
| `0d` | `br_if` | 既存 | [e2e/basic_test.rb](../test/e2e/basic_test.rb)<br>[e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `0e` | `br_table` | M1 | — |
| `0f` | `return` | 既存 | [e2e/basic_test.rb](../test/e2e/basic_test.rb)<br>[e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `10` | `call` | 既存 | [e2e/basic_test.rb](../test/e2e/basic_test.rb)<br>[e2e/spinel_test.rb](../test/e2e/spinel_test.rb)<br>[e2e/wasi_test.rb](../test/e2e/wasi_test.rb)<br>[import_test.rb](../test/import_test.rb) |
| `11` | `call_indirect` | M3 | [e2e/basic_test.rb](../test/e2e/basic_test.rb)<br>[e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `1a` | `drop` | 既存 | [e2e/basic_test.rb](../test/e2e/basic_test.rb)<br>[e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `1b` | `select` | M1 | — |
| `20` | `local.get` | 既存 | [e2e/basic_test.rb](../test/e2e/basic_test.rb)<br>[e2e/spinel_test.rb](../test/e2e/spinel_test.rb)<br>[e2e/wasi_test.rb](../test/e2e/wasi_test.rb)<br>[import_test.rb](../test/import_test.rb) |
| `21` | `local.set` | 既存 | [e2e/basic_test.rb](../test/e2e/basic_test.rb)<br>[e2e/spinel_test.rb](../test/e2e/spinel_test.rb)<br>[e2e/wasi_test.rb](../test/e2e/wasi_test.rb) |
| `22` | `local.tee` | 既存 | — |
| `23` | `global.get` | M2 | [e2e/basic_test.rb](../test/e2e/basic_test.rb) |
| `24` | `global.set` | M2 | [e2e/basic_test.rb](../test/e2e/basic_test.rb) |
| `3f` | `memory.size` | M2 | — |
| `40` | `memory.grow` | M2 | — |
| `fc/08` | `memory.init` | M2 | [e2e/basic_test.rb](../test/e2e/basic_test.rb) |
| `fc/0a` | `memory.copy` | M2 | — |
| `fc/0b` | `memory.fill` | M2 | — |

### i32

| opcode | 命令 | Efflorescence対応段階 | 既存VMテスト記載 |
|---|---|---|---|
| `28` | `i32.load` | M2 | — |
| `2c` | `i32.load8_s` | M2 | — |
| `2d` | `i32.load8_u` | M2 | — |
| `2e` | `i32.load16_s` | M2 | — |
| `2f` | `i32.load16_u` | M2 | — |
| `36` | `i32.store` | M2 | [e2e/basic_test.rb](../test/e2e/basic_test.rb)<br>[e2e/wasi_test.rb](../test/e2e/wasi_test.rb) |
| `3a` | `i32.store8` | M2 | — |
| `3b` | `i32.store16` | M2 | — |
| `41` | `i32.const` | 既存 | [e2e/basic_test.rb](../test/e2e/basic_test.rb)<br>[e2e/spinel_test.rb](../test/e2e/spinel_test.rb)<br>[e2e/wasi_test.rb](../test/e2e/wasi_test.rb) |
| `45` | `i32.eqz` | 既存 | [e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `46` | `i32.eq` | M1 | [e2e/basic_test.rb](../test/e2e/basic_test.rb) |
| `47` | `i32.ne` | M1 | — |
| `48` | `i32.lt_s` | M1 | [e2e/basic_test.rb](../test/e2e/basic_test.rb) |
| `49` | `i32.lt_u` | M1 | — |
| `4a` | `i32.gt_s` | M1 | — |
| `4b` | `i32.gt_u` | M1 | — |
| `4c` | `i32.le_s` | M1 | — |
| `4d` | `i32.le_u` | M1 | [e2e/basic_test.rb](../test/e2e/basic_test.rb) |
| `4e` | `i32.ge_s` | M1 | — |
| `4f` | `i32.ge_u` | M1 | — |
| `67` | `i32.clz` | M1 | — |
| `68` | `i32.ctz` | M1 | — |
| `69` | `i32.popcnt` | M1 | — |
| `6a` | `i32.add` | 既存 | [e2e/basic_test.rb](../test/e2e/basic_test.rb)<br>[e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `6b` | `i32.sub` | 既存 | [e2e/basic_test.rb](../test/e2e/basic_test.rb)<br>[e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `6c` | `i32.mul` | 既存 | [e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `6d` | `i32.div_s` | M1 | — |
| `6e` | `i32.div_u` | M1 | — |
| `6f` | `i32.rem_s` | M1 | — |
| `70` | `i32.rem_u` | M1 | — |
| `71` | `i32.and` | M1 | — |
| `72` | `i32.or` | M1 | — |
| `73` | `i32.xor` | 既存 | — |
| `74` | `i32.shl` | 既存 | — |
| `75` | `i32.shr_s` | M1 | — |
| `76` | `i32.shr_u` | 既存 | — |
| `77` | `i32.rotl` | M1 | [e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `78` | `i32.rotr` | M1 | — |

### i64

| opcode | 命令 | Efflorescence対応段階 | 既存VMテスト記載 |
|---|---|---|---|
| `29` | `i64.load` | M4 | — |
| `30` | `i64.load8_s` | M4 | — |
| `31` | `i64.load8_u` | M4 | — |
| `32` | `i64.load16_s` | M4 | — |
| `33` | `i64.load16_u` | M4 | — |
| `34` | `i64.load32_s` | M4 | — |
| `35` | `i64.load32_u` | M4 | — |
| `37` | `i64.store` | M4 | — |
| `3c` | `i64.store8` | M4 | — |
| `3d` | `i64.store16` | M4 | — |
| `3e` | `i64.store32` | M4 | — |
| `42` | `i64.const` | M4 | [e2e/basic_test.rb](../test/e2e/basic_test.rb)<br>[e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `50` | `i64.eqz` | M4 | [e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `51` | `i64.eq` | M4 | [e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `52` | `i64.ne` | M4 | — |
| `53` | `i64.lt_s` | M4 | [e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `54` | `i64.lt_u` | M4 | — |
| `55` | `i64.gt_s` | M4 | — |
| `56` | `i64.gt_u` | M4 | — |
| `57` | `i64.le_s` | M4 | — |
| `58` | `i64.le_u` | M4 | — |
| `59` | `i64.ge_s` | M4 | — |
| `5a` | `i64.ge_u` | M4 | — |
| `79` | `i64.clz` | M4 | — |
| `7a` | `i64.ctz` | M4 | [e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `7b` | `i64.popcnt` | M4 | [e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `7c` | `i64.add` | M4 | [e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `7d` | `i64.sub` | M4 | — |
| `7e` | `i64.mul` | M4 | [e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `7f` | `i64.div_s` | M4 | [e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `80` | `i64.div_u` | M4 | — |
| `81` | `i64.rem_s` | M4 | — |
| `82` | `i64.rem_u` | M4 | — |
| `83` | `i64.and` | M4 | — |
| `84` | `i64.or` | M4 | — |
| `85` | `i64.xor` | M4 | — |
| `86` | `i64.shl` | M4 | [e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `87` | `i64.shr_s` | M4 | — |
| `88` | `i64.shr_u` | M4 | — |
| `89` | `i64.rotl` | M4 | [e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |
| `8a` | `i64.rotr` | M4 | [e2e/spinel_test.rb](../test/e2e/spinel_test.rb) |

### f32

| opcode | 命令 | Efflorescence対応段階 | 既存VMテスト記載 |
|---|---|---|---|
| `2a` | `f32.load` | M5 | — |
| `38` | `f32.store` | M5 | — |
| `43` | `f32.const` | M5 | [e2e/basic_test.rb](../test/e2e/basic_test.rb) |
| `5b` | `f32.eq` | M5 | — |
| `5c` | `f32.ne` | M5 | — |
| `5d` | `f32.lt` | M5 | — |
| `5e` | `f32.gt` | M5 | — |
| `5f` | `f32.le` | M5 | — |
| `60` | `f32.ge` | M5 | — |
| `8b` | `f32.abs` | M5 | — |
| `8c` | `f32.neg` | M5 | — |
| `8d` | `f32.ceil` | M5 | — |
| `8e` | `f32.floor` | M5 | — |
| `8f` | `f32.trunc` | M5 | — |
| `90` | `f32.nearest` | M5 | — |
| `91` | `f32.sqrt` | M5 | — |
| `92` | `f32.add` | M5 | — |
| `93` | `f32.sub` | M5 | — |
| `94` | `f32.mul` | M5 | — |
| `95` | `f32.div` | M5 | — |
| `96` | `f32.min` | M5 | — |
| `97` | `f32.max` | M5 | — |
| `98` | `f32.copysign` | M5 | — |

### f64

| opcode | 命令 | Efflorescence対応段階 | 既存VMテスト記載 |
|---|---|---|---|
| `2b` | `f64.load` | M5 | — |
| `39` | `f64.store` | M5 | — |
| `44` | `f64.const` | M5 | [e2e/basic_test.rb](../test/e2e/basic_test.rb) |
| `61` | `f64.eq` | M5 | — |
| `62` | `f64.ne` | M5 | — |
| `63` | `f64.lt` | M5 | — |
| `64` | `f64.gt` | M5 | — |
| `65` | `f64.le` | M5 | — |
| `66` | `f64.ge` | M5 | — |
| `99` | `f64.abs` | M5 | — |
| `9a` | `f64.neg` | M5 | — |
| `9b` | `f64.ceil` | M5 | — |
| `9c` | `f64.floor` | M5 | — |
| `9d` | `f64.trunc` | M5 | — |
| `9e` | `f64.nearest` | M5 | — |
| `9f` | `f64.sqrt` | M5 | — |
| `a0` | `f64.add` | M5 | — |
| `a1` | `f64.sub` | M5 | — |
| `a2` | `f64.mul` | M5 | — |
| `a3` | `f64.div` | M5 | — |
| `a4` | `f64.min` | M5 | — |
| `a5` | `f64.max` | M5 | — |
| `a6` | `f64.copysign` | M5 | — |

### convert

| opcode | 命令 | Efflorescence対応段階 | 既存VMテスト記載 |
|---|---|---|---|
| `a7` | `i32.wrap_i64` | M4 | — |
| `a8` | `i32.trunc_f32_s` | M5 | — |
| `a9` | `i32.trunc_f32_u` | M5 | — |
| `aa` | `i32.trunc_f64_s` | M5 | — |
| `ab` | `i32.trunc_f64_u` | M5 | — |
| `ac` | `i64.extend_i32_s` | M4 | — |
| `ad` | `i64.extend_i32_u` | M4 | [e2e/basic_test.rb](../test/e2e/basic_test.rb) |
| `ae` | `i64.trunc_f32_s` | M5 | — |
| `af` | `i64.trunc_f32_u` | M5 | — |
| `b0` | `i64.trunc_f64_s` | M5 | — |
| `b1` | `i64.trunc_f64_u` | M5 | — |
| `b2` | `f32.convert_i32_s` | M5 | — |
| `b3` | `f32.convert_i32_u` | M5 | — |
| `b4` | `f32.convert_i64_s` | M5 | — |
| `b5` | `f32.convert_i64_u` | M5 | — |
| `b6` | `f32.demote_f64` | M5 | — |
| `b7` | `f64.convert_i32_s` | M5 | — |
| `b8` | `f64.convert_i32_u` | M5 | — |
| `b9` | `f64.convert_i64_s` | M5 | — |
| `ba` | `f64.convert_i64_u` | M5 | — |
| `bb` | `f64.promote_f32` | M5 | — |
| `bc` | `i32.reinterpret_f32` | M5 | — |
| `bd` | `i64.reinterpret_f64` | M5 | — |
| `be` | `f32.reinterpret_i32` | M5 | — |
| `bf` | `f64.reinterpret_i64` | M5 | — |
| `c0` | `i32.extend8_s` | M1 | — |
| `c1` | `i32.extend16_s` | M1 | — |
| `c2` | `i64.extend8_s` | M4 | — |
| `c3` | `i64.extend16_s` | M4 | — |
| `c4` | `i64.extend32_s` | M4 | — |
| `fc/00` | `i32.trunc_sat_f32_s` | M5 | — |
| `fc/01` | `i32.trunc_sat_f32_u` | M5 | — |
| `fc/02` | `i32.trunc_sat_f64_s` | M5 | [e2e/basic_test.rb](../test/e2e/basic_test.rb) |
| `fc/03` | `i32.trunc_sat_f64_u` | M5 | [e2e/basic_test.rb](../test/e2e/basic_test.rb) |
| `fc/04` | `i64.trunc_sat_f32_s` | M5 | — |
| `fc/05` | `i64.trunc_sat_f32_u` | M5 | — |
| `fc/06` | `i64.trunc_sat_f64_s` | M5 | — |
| `fc/07` | `i64.trunc_sat_f64_u` | M5 | — |

## 対象外

既存VMに実行ハンドラがない命令（デコード自体も完全とは限らない）:

`try`, `catch`, `throw`, `rethrow`, `throw_ref`, `return_call`, `return_call_indirect`, `call_ref`, `return_call_ref`, `delegate`, `catch_all`, `select_t`, `try_table`, `table.get`, `table.set`, `data.drop`, `table.init`, `elem.drop`, `table.copy`, `table.grow`, `table.size`, `table.fill`。

生成済みだが命令表から到達しないハンドラ: `f32_eqz`, `f64_eqz`, `i64_extend_i64_s`, `i64_extend_i64_u`。生成コードの `when` の数だけを数えると過大になる。

## 実行確認と既存実装の問題

`bundle exec rake test`: **117 tests / 9,273 assertions / 0 failures / 0 errors / 34 omissions**。
省略を含むためSpinelの全面検証済みとは扱わない。今回、新たにSpinelビルドは行っていない。

追加の7ケースは `wasm-tools parse` と `wasm-tools validate` に通したモジュールを、CRubyの既存VMで実行した。

| ケース | 観測結果 | 対応方針 |
|---|---|---|
| `f32.const 2.5; f32.nearest` | `F32(3.0)` | ties-to-evenとの不一致をM5の独立期待値テストにする |
| `memory.fill` にbyte=256 | `RangeError: 256 out of char range` | 下位8bitを扱うテストをM2で用意 |
| 1ページのmemoryにaddress=65536で `i32.store` | trapせずmemoryが65540バイトに伸びる | 境界外storeを旧VMとの一致で合格させない |
| 1ページのmemoryでsrc=65535, dst=0, length=2の `memory.copy` | trapせずmemoryが65535バイトに縮む | source/destination両方の境界を検証 |
| i32結果型でf32結果の関数を `call_indirect` | `F32(1.0)` が返る | 間接呼び出しの型検査をM3の要件にする |
| 2個のi32結果をexportから返す | `NotImplementedError` | multi-valueを今回の必須要件から除外 |
| 内部関数にi64=41を渡し1を加える | `I64(42)` | 非i32の内部実行と公開API制約を区別 |

これは不具合の網羅調査ではない。NaN、符号付きゼロ、floatの丸め、load境界、memory.grow失敗等は引き続き個別検証が必要。
修正はこの調査では行っていない。互換性のために上記の誤動作をEfflorescenceへ複製しない。

## 各マイルストーンの検証バックログ

| 段階 | 正常系 | 境界・trap・相互作用 |
|---|---|---|
| M1 | 比較のsigned/unsigned、整数演算、if両分岐、select、br_table全ターゲット | 0除算、MIN/-1、shift幅、0のclz/ctz、分岐結果の合流、片側return/unreachable、localの旧値保存 |
| M2 | 全load/store幅、global読み書き、size/grow、init/copy/fill | offset込み境界、短いsource、重複copy、ゼロ長、grow失敗、可変global、未使用loadのtrap維持 |
| M3 | imported/definedの関数index、host引数と結果、間接call、fd_write | 型不一致、null/out-of-range table、ホスト側のmemory/global更新、例外後の再呼び出し、startからhost call |
| M4 | i64演算・メモリ・混在シグネチャ、i32との変換 | 2^63/2^64付近、overflow、signed/unsigned、再帰・フレーム再利用、Spinelの中間値overflow |
| M5 | f32/f64演算・メモリ、全変換 | NaN/infinity/±0、f32丸め、nearestのtie、trunc境界とtrap、trunc_sat、reinterpretのビット保存 |
| M6 | 対象188命令と初期化・API・実プログラム | 未最適化/最適化/旧VMを独立instanceで比較し、状態更新・trap・hostログを検査 |

全段階で既存i32ベンチマークの退行を確認する。旧VMに既知の問題があるケースは独立期待値を正とし、差分を明記する。
命令追加はTranslator/VMだけでなく、Opcodeのread/write/分岐先情報、Lowerer、semantic/flat両実行経路、RegisterValidation、Inspection、最適化の適用範囲をセットで見直す。

M0の**洗い出し**は本書で完了。M0で提案した全命令の差分テスト基盤の実装・全境界値の実行検証は未実施であり、次の作業として残る。

## 調査元

- [命令表とoperand定義](../lib/wardite/instruction.rb)
- [デコーダーとsectionの読み込み](../lib/wardite/load.rb)
- [Runtime・Store・公開呼び出しAPI](../lib/wardite.rb)
- `lib/wardite/alu_{i32,i64,f32,f64}.generated.rb`, `lib/wardite/convert.generated.rb`
- [Translator](../lib/wardite/efflorescence/translator.rb)、[IR](../lib/wardite/efflorescence/ir.rb)、[VM](../lib/wardite/efflorescence/vm.rb)
- [既存spec runner](../spec/runner.rb): 非i32引数、複数結果、浮動小数点期待値等の扱いを確認してから再利用する。全仕様の検証器として無条件には扱わない。
