# ADR 0011: Efflorescenceのglobalを整数配列で保持する

- **状態** 実装・計測済み。[実装と計測の記録](../efflorescence-unboxed-globals.md)
- **日付** 2026-11-12
- **前提** [ruby.wasm対応フェーズ2](0008-efflorescence-ruby-wasm-phase2.md)の「7. ゲスト実行時間の改善」

## 背景

Spinel版でRuby 4.0.9のWasmをキャッシュヒットで起動し、1回プロファイルした（1 ms間隔、1151サンプル）。ゲスト実行（`VM#execute`）の743サンプルのうち、`execute_flat` から呼ばれる次の関数が boxed 値を扱っていた。

| 関数 | サンプル数 | 内容 |
|---|---:|---|
| `sp_class_le_mod`、`sp_class_anc_walk`、`sp_class_anc_step` | 約70 | `is_a?` の祖先探索 |
| `sp_poly_bitop` | 31 | boxed 値のビット演算 |
| `sp_pd_58a8a817` | 28 | `value` の動的ディスパッチ |

生成C（`spinel -c`）で `execute_flat` が呼ぶ関数を調べると、`is_a?` とビット演算と動的ディスパッチをすべて含むのは `StoreAccess#global_get` だけだった。

[StoreAccess#global_get](../../lib/wardite/efflorescence/store_access.rb) は次の処理をする。

1. `Wardite::Global#value` を読む。型が `wasmValue`（`I32`、`I64`、`F32`、`F64` の合併）なので boxed 値になる。
2. `value.is_a?(Wardite::I32)` で型を確かめる。
3. `value.value & 0xffffffff` で整数を取り出す。

`global_set` は書き込みのたびに `Wardite::I32.new(value)` でオブジェクトを確保する。

このWasmのglobalは3個で、いずれも可変のi32。Cからコンパイルしたコードは、スタックポインタのglobalを多くの関数の入口と出口で読み書きする。

CRuby版の `--mir-profile` で同じ起動（`--disable-gems -e 'puts RUBY_DESCRIPTION'`）のopcode別の実行回数を数えた。全66,500,266命令のうち、`GLOBAL_GET` は8,006,941回（12.04%）で3番目に多く、`GLOBAL_SET` は455,695回（0.69%）だった。上位は `BR_IF_ZERO`（18.74%）、`COPY`（15.53%）、`GLOBAL_GET`、`I32_EQZ`（10.86%）、`I32_EQ`（9.90%）の順で、globalを読んで比較し分岐する並びが多い。

## 決定

EfflorescenceのVMが、globalの値を整数配列で保持する。実行ループはこの配列だけを読み書きする。`Wardite::Global` オブジェクトとは、VMの外から観測できる境界で同期する。

### 整数配列

- `VM` に `@global_bits`（`Array[Integer]`）を持たせる。要素はglobalのindex順で、レジスタと同じ表現にする（i32は符号なし32ビット、i64は符号付き64ビット、f32とf64はビット列）。
- `GLOBAL_GET`、`I64_GLOBAL_GET`、`F32_GLOBAL_GET`、`F64_GLOBAL_GET` は `registers[a] = global_bits[b]` にする。
- `GLOBAL_SET` とその各型版は `global_bits[a] = registers[b]` にする。
- `execute_flat` の冒頭で `@global_bits` をローカル変数に取り、Spinelが整数専用配列（`sp_IntArray`）として扱える形にする。
- globalの型と可変性はMIR変換時に検査済みなので、実行時の `is_a?` は不要になる。

### 同期する境界

VMは単一スレッドで動き、Wasmの実行中に外部が `Global` を読み書きできるのはホスト関数の呼び出し中だけである。次の4か所で同期する。

| 境界 | 方向 |
|---|---|
| 公開呼び出し（`execute_public`）の開始時 | `Global` → 整数配列 |
| ホスト関数の呼び出し直前（`invoke_host`） | 整数配列 → `Global` |
| ホスト関数からの復帰直後 | `Global` → 整数配列 |
| 公開呼び出しの終了時（正常終了、trap、未捕捉例外） | 整数配列 → `Global` |

終了時の書き戻しは `ensure` で行う。ホスト関数がWasmの公開関数を再入で呼んだ場合も、内側の呼び出しが開始時と終了時に同期するので整合する。

同期は全globalを対象にする。書き戻しでは、値が変わったglobalだけ `Wardite::I32` などのオブジェクトを作り直す。globalの数が多いモジュールで同期が負担になった場合は、書き込みがあったことを示すフラグの導入を別途検討する。

`StoreAccess` のglobal用メソッドは、同期処理とRuby API用として残す。スタックVMと `Wardite::Global` クラスは変更しない。

### 不採用の案

- **`Wardite::Global` 自体に整数を持たせる**: 同期は不要になるが、スタックVMのglobal読み出しで毎回オブジェクトを作ることになり、既定エンジンが退行する。
- **`global_get` 内の型検査だけを外す**: `Global#value` が合併型のままなので、動的ディスパッチと `global_set` のオブジェクト確保が残る。

### 残りの boxed 経路

生成Cでは、`Function#memory_site`（`sp_poly_truthy`）、`VM#execute_indirect`、`VM#propagate` にも boxed 値の操作がある。globalの変更後にプロファイルを取り直し、上位に残る場合は別の変更として扱う。

`GLOBAL_GET` と直後の比較・分岐を1命令にまとめる融合も、globalの変更後に実行回数を取り直して検討する。このADRでは決めない。

## 検証

- 生成Cで、`execute_flat` の `GLOBAL_GET` と `GLOBAL_SET` の分岐に `sp_poly_` と `sp_box_` で始まる呼び出しがないことを確認する。[生成Cのガード](../efflorescence-generated-c-guards.md)の検査に追加する。
- ホスト関数の中からglobalを読んだ値が、直前のWasmの書き込みを反映している。
- ホスト関数の中でglobalを書いた値が、復帰後のWasmから読める。
- 別インスタンスからimportした可変globalを、双方の書き込みが互いに見える。
- trapと未捕捉例外で終了したあと、Ruby APIから読むglobalが最後の書き込みを反映している。
- ホスト関数からの再入呼び出しで値が失われない。
- i64、f32、f64のglobalで、符号とビット列（NaNのペイロードを含む）が保たれる。
- 436フィクスチャのparityがCRubyとSpinelで通る。

計測は、Ruby 4.0.9のWasmのキャッシュヒットでゲスト実行時間（プロセス全体から `load_from_buffer` を引いた値）を変更前後で各3回以上、別プロセスで行う。既存のi32、i64、float、call、Storeのベンチマークで小さなモジュールへの影響も調べる。

## 受け入れ条件

- Spinel版でRuby 4.0.9のゲスト実行時間が変更前より短くなることを計測で示す。
- CRuby版のゲスト実行時間と既存ベンチマークが退行しない。
- [verify_ruby_wasm.rb](../../scripts/verify_ruby_wasm.rb) の3ケースがWasmtimeと一致する。
- CRubyのtest・型チェック・parityと、Spinelの回帰試験が通る。
