# ADR 0021: 線形メモリ・i64・floatを使う関数にも最適化パスを適用する

- **状態** 提案
- **日付** 2026-11-17
- **基準** Wardite 1.2.2 `5baaf38`
- **関連** [ADR 0001](0001-efflorescence-m1-control-and-eh.md)、[ADR 0002](0002-efflorescence-m2-memory-and-globals.md)、[ADR 0004](0004-efflorescence-m4-i64.md)、[ADR 0005](0005-efflorescence-m5-floating-point.md)、[ADR 0006](0006-efflorescence-m6-coverage-parity.md)、[ADR 0018](0018-efflorescence-real-workload-measurement.md)（計測の基準）

## 決定

`Optimizer#optimize_function` と `Passes::Inlining` は、5つのフラグのいずれかを持つ関数を最適化しない。フラグは `uses_store`・`uses_dynamic_calls`・`uses_i64`・`uses_float`・`uses_eh` である。このうち `uses_eh` を除く4つの除外を、この順に1つずつ外す。

外す前に、CopyPropagationの生存解析が副表の読み出しを見ていない不具合を直す。除外を外すと、この不具合で誤変換が起きるためである。また、`rake parity` を既定の最適化構成でも実行できるようにする。

この ADR では次のことを行わない。

- `uses_eh` の除外を外す
- Inliningのcallee側の除外を外す
- i64やメモリ命令の即値形、load・storeのfusion、新しいsuperinstructionを足す

即値形やsuperinstructionの追加は、除外を外した後のプロファイルを見て別のADRで決める。

## 背景

### 現実のWasmでは局所最適化がほとんど動いていない

[optimizer.rb](../../lib/wardite/efflorescence/optimizer.rb#L579) の入口で、5つのフラグのいずれかを持つ関数は全パスを飛ばす。Inliningも、caller側（[optimizer.rb](../../lib/wardite/efflorescence/optimizer.rb#L204)）とcallee側の `eligible?`（[optimizer.rb](../../lib/wardite/efflorescence/optimizer.rb#L217)）で同じ条件を使う。

フラグは次の命令で立つ。

| フラグ | 立つ条件 |
|---|---|
| `uses_store` | load・store、`global.get`・`global.set`、`memory.*`（[translator.rb](../../lib/wardite/efflorescence/translator.rb#L194) の `STORE_CODES`）。到達不能なコードでも立つ |
| `uses_dynamic_calls` | ホスト関数の呼び出し（[translator.rb](../../lib/wardite/efflorescence/translator.rb#L482)）と `call_indirect`（[translator.rb](../../lib/wardite/efflorescence/translator.rb#L503)） |
| `uses_i64` | i64型のパラメータ・local・結果・レジスタ、i64のload・store・global・定数 |
| `uses_float` | f32・f64型の同じ要素 |
| `uses_eh` | exnrefのlocal、`try_table`、`throw`、`throw_ref`、exnrefを結果に持つblock |

wardite-benchesのWASIサンプルで、フラグごとの関数の数を数えた。

| Wasm | 定義された関数 | `uses_store` | `uses_i64` | `uses_dynamic_calls` | どのフラグもない |
|---|---:|---:|---:|---:|---:|
| `base64_codec.wasm` | 284 | 234 | 86 | 67 | 45 |
| `png_grayscale.wasm` | 391 | 337 | 120 | 76 | 49 |

最適化の対象になるのは、どのフラグもない1割強の関数だけである。`uses_float` と `uses_eh` を持つ関数はなかった。Ruby 3.4.2 Wasmの静的な集計でも、8,161関数のうち最適化の対象は292関数（3.58%）だった（[MIR生成性能調査](../efflorescence-mir-generation-performance.md)）。

[wardite-benches](https://github.com/udzura/wardite-benches/tree/286de8be5226a4b41dc8e1b597b6717d761e9156) のWASIサンプルで、実行したMIR命令の内訳を数えた。CRubyで `mir_profile: true` を指定し、`Metrics#opcode_counts` を集計した。命令数はランタイムに依存しない。

| 入力 | 全命令 | `COPY` | `I32_ADD` |
|---|---:|---:|---:|
| `base64_codec encode`（`data.bin`、256 KiB） | 5,326,888 | 12.5% | 20.3% |
| `base64_codec decode`（`data.b64`） | 4,934,514 | 25.1% | 16.4% |
| `png_grayscale`（`rgb.png`、256×256） | 3,849,147 | 22.6% | 31.4% |

CopyPropagationは `COPY` を減らし、ImmediateSpecializationは定数を足す `I32_ADD` を `I32_ADD_IMM` に置き換える。今はどちらもこれらの関数に適用されない。i32だけの `xorshift` ではWarditeがiwasmの1.2〜2.5倍の時間で済む一方、WASIのサンプルでは5.6〜10.7倍かかる（[ADR 0018](0018-efflorescence-real-workload-measurement.md)）。

### 除外は保守的な初期判断で、解除は先送りされていた

ADR 0002は「最適化の解禁やload/store fusionはM2の完成後、測定と別のレビューを経て行う」とした。ADR 0006は「uses_i64/uses_float等の最適化除外解除は、対応範囲が揃った後の別判断」とした。ADR 0003、0004、0005は「保守的に除外」とだけ書き、パスが壊れる具体的な理由は挙げていない。`uses_eh` だけは、ADR 0001が「例外edgeでの値の生存をまだ証明できないため」と理由を書いている。

### 除外を外すと誤変換する箇所が1つある

`CopyPropagation#remove_overwritten_copies`（[optimizer.rb](../../lib/wardite/efflorescence/optimizer.rb#L426)）は、後方の生存解析で `Opcode.read_positions` だけを見る。命令の中の固定位置にあるレジスタしか読み出しとして数えない。

一方、次の命令は引数を副表から読む。副表の読み出しは `Function#read_count` と `Function#read_at`（[ir.rb](../../lib/wardite/efflorescence/ir.rb#L912)）でしか列挙されない。

- `MEMORY_INIT`・`MEMORY_COPY`・`MEMORY_FILL`：`MemorySite` のsources
- `CALL_HOST`：`DynamicCallSite` の引数
- `THROW`：payload

`COPY r1, c5; MEMORY_FILL（r1を読む）; COPY r1, c7` にこのパスを適用すると、最初の `COPY` が消える。`CALL_HOST` の引数でも同じことが起きる。どちらもCRubyで再現した。localは関数の入口で定義済みとして扱われる（[register_validation.rb](../../lib/wardite/efflorescence/register_validation.rb#L170)）ため、RegisterValidationはこの誤りを検出しない。

同じパスの他の処理は副表を正しく扱う。`Analysis` は副表の読み出しも数える（[optimizer.rb](../../lib/wardite/efflorescence/optimizer.rb#L145)）ので、`single_use?` と `remove_dead_copies` は安全である。`propagate` は固定位置のオペランドだけを書き換える。副表の読み出しは置き換えずに残るだけなので、結果は変わらない。

### 最適化した経路の検証が足りない

`rake parity` は、最適化をすべて無効にした構成（`[:all]`）だけで188命令とEHを照合する（[run_efflorescence_manifest.rb](../../test/support/run_efflorescence_manifest.rb#L103)）。RegisterValidationが検査するのは型、定義前の読み出し、定数レジスタへの書き込みで、変換の前後で意味が同じかは見ない。

既定の構成を含めて比較するテストもある。[efflorescence_parity_test.rb](../../test/efflorescence_parity_test.rb) と [spinel_parity_test.rb](../../test/e2e/spinel_parity_test.rb) は、既定、全無効、各パスを1つだけ無効にした構成で小さなfixtureを実行する。

## パスごとの扱い

| パス | 対象の命令 | 除外を外したときの扱い |
|---|---|---|
| CopyPropagation | 全opcode。opcode表はload・store・globalを含む | 生存解析を副表の読み出しに対応させる |
| ImmediateSpecialization | `I32_ADD`〜`I32_SHR_U` と、i32型の定数 | 変更しない。i64・floatの関数でもi32の命令だけを書き換える |
| BranchFusion | `I32_EQZ` と `BR_IF` の組 | 変更しない |
| Superinstructions | `I32_SHR_U_IMM`・`I32_SHL_IMM` と `I32_XOR` の組 | 変更しない |
| Inlining（caller側） | 1段のleaf関数の展開 | 除外を外す |
| Inlining（callee側） | 命令の許可リストに入る8命令以下の関数 | 除外を残す |

Inliningのcallee側を残す理由は2つある。`expand` はcalleeのレジスタを型指定なしで割り当てるので、すべてi32になる（[optimizer.rb](../../lib/wardite/efflorescence/optimizer.rb#L313)）。また、calleeの `MemorySite` などの副表をcallerへコピーしない。どちらも、直さずに除外を外すとRegisterValidationか実行で失敗する。

ImmediateSpecialization、BranchFusion、Superinstructionsがi64・float・メモリ命令の関数で正しく動くことは、コードを読んだうえでの推測である。各段階の検証で確かめる。

## 段階

各段階を別のPRにし、段階1・2は既存の除外条件下で生成コードの一致とテストの成功を合格条件にする。命令数と実行時間の改善判定は、除外を解除する段階3以降に適用する（[計測と受け入れ条件](#計測と受け入れ条件)）。lowering後のコードが変わる段階では `MIRCache::CODE_VERSION`（[mir_cache.rb](../../lib/wardite/efflorescence/mir_cache.rb#L16)）を上げ、既存のMIR2キャッシュを使わせない。起動スナップショットのキーはキャッシュのキーを含むので、同時に無効になる。

1. 生存解析の修正：`remove_overwritten_copies` で `Function#read_count` と `Function#read_at` を使う。上の再現手順を、`MEMORY_INIT`・`MEMORY_COPY`・`MEMORY_FILL`・`CALL_HOST` の単体テストにする。今の除外の下では生成されるコードは変わらない。
2. parityを既定の構成でも実行する：`run_efflorescence_manifest.rb` で、`[:all]` に加えて既定の構成でも結果を照合する。
3. `uses_store` の除外を外す：`optimize_function` とInliningのcaller側から外す。
4. `uses_dynamic_calls` の除外を外す
5. `uses_i64` の除外を外す：[ADR 0020](0020-efflorescence-inline-i64-bit-operations.md) のVM側の変更とは独立に進められる。
6. `uses_float` の除外を外す

`uses_eh` の除外は残す。例外edgeでの生存は、ADR 0001の時点から証明されていない。また、catch clauseが書くレジスタ（[ir.rb](../../lib/wardite/efflorescence/ir.rb#L618)）を `Analysis` が書き込みとして数えていない可能性がある。これは未確認である。除外を外すなら、これらを先に確かめる別のADRにする。

除外を固定している次のテストは、段階3以降で書き換える。最適化しないことの確認から、構成の間で結果が同じことの確認に変える。

- [efflorescence_m2_globals_test.rb](../../test/efflorescence_m2_globals_test.rb#L44)
- [efflorescence_m2_integration_test.rb](../../test/efflorescence_m2_integration_test.rb#L42)
- [efflorescence_m1_test.rb](../../test/efflorescence_m1_test.rb#L162)（`uses_eh` だけを見るので、このADRの範囲では変わらない）

## 守る契約

- 副作用のある命令を削除、移動、融合しない。副作用のある命令は、store、`global.set`、`memory.grow` などのメモリ操作、呼び出し、trapし得る命令である。今のパスで削除するのは `COPY` だけで、融合するのは副作用のないi32命令の組だけである。
- レジスタの値はビット列として扱う。`COPY` は型を区別せずに値を移す（[vm.rb](../../lib/wardite/efflorescence/vm.rb#L665)）。RegisterValidationは `COPY` の両辺が同じ型であることを検査する。
- 最適化した結果も、今と同じRegisterValidationを通す。検証を緩めない。
- `--mir-disable` の各値の意味と、全無効の構成で生成されるMIRは変えない。

## 検証

- 段階1の単体テストに加え、既存の構成マトリクスのテスト（[efflorescence_parity_test.rb](../../test/efflorescence_parity_test.rb) など）を各段階で通す。
- `bundle exec rake test`、`bundle exec rake check`、`make spinel-test RUBY="bundle exec ruby"`、既定の構成を加えた `bundle exec rake parity` を実行する。
- wardite-benchesの全サンプルの出力が、Wasmtimeとバイト単位またはビット単位で一致することを `script/compare` で確かめる。
- 大きな実プログラムとしてruby.wasmを、既定と `--mir-disable all` で実行し、出力が一致することを確かめる。[ADR 0008](0008-efflorescence-ruby-wasm-phase2.md) の検証ケースを使う。

## 計測と受け入れ条件

[ADR 0018](0018-efflorescence-real-workload-measurement.md) の手順と条件に従う。一次指標は2つある。1つはwardite-benchesのWASIサンプルで実行したMIR命令の総数で、段階3以降で総数と `COPY`・定数との `I32_ADD` の変化を測る。もう1つは16倍の入力でのプロセス全体の時間である。

最適化の対象が増えるので、ロードとMIR準備の時間は増える。CopyPropagationの `propagate` は命令数×レジスタ数に比例し、大きな関数で時間がかかる（[ADR 0016](0016-efflorescence-generation-tagged-copy-propagation.md)）。段階3以降では、既定サイズの入力のプロセス全体の時間が悪化しないことを、採用の条件にする。悪化する場合は、関数の大きさで最適化を打ち切る閾値を同じPRで検討する。
