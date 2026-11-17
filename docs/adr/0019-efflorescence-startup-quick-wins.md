# ADR 0019: ロード時のstore命令の判定と、semantic IRの複製を減らす

- **状態** 提案
- **日付** 2026-11-17
- **基準** Wardite 1.2.2 `5baaf38`、Spinel `58ee636`（CIの `SPINEL_REF`）、`-O2`、既定の整数overflow検査
- **関連** [ADR 0010](0010-efflorescence-mir2-cache-function-restore.md)、[ADR 0014](0014-efflorescence-mir-build-validation-and-decoding.md)、[ADR 0015](0015-efflorescence-selective-inline-snapshots.md)、[ADR 0018](0018-efflorescence-real-workload-measurement.md)（計測の基準）、[ADR 0022](0022-efflorescence-lazy-function-build.md)

## 決定

ロードとMIR準備の時間を、次の2つの変更で減らす。どちらも生成されるMIRとbytecodeを変えない。

1. **store命令の判定を表引きにする。** `Translator#translate_function` は、Wasmの命令ごとに `STORE_CODES.include?(code)` を呼ぶ。これを、`BINARY.key?(code)` と同じくHashの表引きにする。
2. **通常の実行ではsemantic IRを複製しない。** `Optimizer#optimize` は、最初にsemantic IR全体を複製してから最適化する。semantic IRを保持するのはMIRの表示と検査のためだけなので、その場合にだけ複製する。

RegisterValidationの時間は、この ADR では減らさない。

## 背景

### ロードとMIR準備が既定サイズの入力の時間の3〜6割を占める

[ADR 0018](0018-efflorescence-real-workload-measurement.md) のベースラインでは、ロードとMIR準備（`load_from_buffer`）にBase64で約29 ms、PNGで約61〜67 msかかった。既定サイズの入力では、プロセス全体の時間の3割（Base64）から6割（PNG）にあたる。

ロードを30回繰り返すプログラムをSpinel `58ee636` でビルドし、macOSの `sample` で1 ms間隔のプロファイルを取った。次の表は、`load_from_buffer` を含むサンプルに対する割合である。GCは、ほかの処理の中で起きた分を重ねて数えている。

| 処理 | `png_grayscale.wasm` | `base64_codec.wasm` |
|---|---:|---:|
| `VM#build_mir` | 76% | 77% |
| 　`Translator#translate_function` | 39% | 38% |
| 　　うち `STORE_CODES.include?` | 12% | 10% |
| 　RegisterValidation | 13% | 12% |
| 　`IR#copy` | 11% | 11% |
| 　`Lowerer#compile` | 5% | 6% |
| コードセクションのデコード | 23% | 21% |
| GC | 28% | 27% |

この ADR の2つの変更は、表の `STORE_CODES.include?` と `IR#copy` を対象にする。2つを合わせて、ロードとMIR準備の約2割にあたる。

### store命令の判定が命令ごとに配列を走査している

`STORE_CODES` は、load・store、`global.get`・`global.set`、`memory.*` のSymbolを並べた配列である（[translator.rb](../../lib/wardite/efflorescence/translator.rb#L194)）。`translate_function` は、Wasmの命令ごとに `STORE_CODES.include?(code)` を呼ぶ（[translator.rb](../../lib/wardite/efflorescence/translator.rb#L285)）。Spinelはこの配列を要素型の決まらない配列（`sp_PolyArray`）として扱い、`include?` は要素を先頭から比べる。生成Cで、この呼び出しが `sp_PolyArray_include` になることを確かめた。

### semantic IRの複製は表示と検査のためだけにある

`VM#build_mir` は、semantic IRとoptimized IRの両方を `@semantic_ir` と `@optimized_ir` に保持する（[vm.rb](../../lib/wardite/efflorescence/vm.rb#L160)）。`Optimizer#optimize` は、semantic IRを書き換えないように、最初にIR全体を複製する（[optimizer.rb](../../lib/wardite/efflorescence/optimizer.rb#L561)）。

保持したsemantic IRを読むのは、`VM#semantic_ir`、`VM#dump_mir` と、それを使うテストだけである。MIR2キャッシュがヒットしたときは、すでにsemantic IRを保持していない。`VM#semantic_ir` は、保持していなければ `restore_inspection_ir` で全体を作り直す（[vm.rb](../../lib/wardite/efflorescence/vm.rb#L74)、[ADR 0010](0010-efflorescence-mir2-cache-function-restore.md)）。

[ADR 0015](0015-efflorescence-selective-inline-snapshots.md) は、この最初の複製を維持すると決めた。semantic IRを保持する契約があり、複製をやめると、loweringや後の書き換えがsemantic IRへ漏れるためである。semantic IRの遅延再生成は、対象外とした。この ADR は、その遅延再生成を採用する。表示と検査では今と同じく複製した組を作るので、ADR 0015が守った分離は保たれる。

## 1. store命令の判定を表引きにする

`STORE_CODES` から、コードを鍵にしたHashの定数を作る。`translate_function` では、そのHashの `key?` で判定する。`STORE_CODES` を参照するほかの箇所は変えない。

## 2. 通常の実行ではsemantic IRを複製しない

`VM#build_mir` に、semantic IRを保持するかどうかの引数を足す。

- `VM#initialize` からの通常の構築では保持しない。`Optimizer#optimize` は、受け取ったIRをその場で最適化する。`@semantic_ir` と `@optimized_ir` には何も入れない。
- `restore_inspection_ir` からの構築では、今と同じく複製して両方を保持する。

`VM#semantic_ir`、`VM#optimized_ir`、`VM#dump_mir` は、MIR2キャッシュのヒット時と同じく、初回に `restore_inspection_ir` で作り直す。CLIの `--mir-dump` は、キャッシュを使わずに `dump_mir` を呼ぶ。作り直しの分だけ時間は増えるが、出力は変わらない。

`--mir-profile` のInstrumentationは、別にIRを複製する（[inspection.rb](../../lib/wardite/efflorescence/inspection.rb#L78)）。この複製は計測の構成でだけ起きるので、変えない。

## RegisterValidationを対象にしない理由

RegisterValidationは、ロードとMIR準備の12〜13%を使う。store命令の判定やIRの複製と同じ程度である。ただし、時間はレジスタの読み出しと、作業用の配列の複製が起こすGCに分散していて、1か所に集中していない。[ADR 0014](0014-efflorescence-mir-build-validation-and-decoding.md) で、配列を作らない読み出しにすでに変えている。

検証を省略しないという ADR 0014の方針は維持する。検証する関数そのものを減らす方法は、[ADR 0022](0022-efflorescence-lazy-function-build.md) で扱う。

## 守る契約

- 生成されるsemantic MIR、optimized MIR、bytecode、side tableを変えない。`MIRCache::CODE_VERSION` は上げない。
- `VM#semantic_ir` と `VM#optimized_ir` は、今と同じく別々のオブジェクトの組を返す。片方の書き換えがもう片方へ漏れない。
- `restore_inspection_ir` で作り直したMIRは、実行に使っているMIRと同じ内容になる。Translatorと各パスが同じ入力に対して同じ出力を返すことに依存する。これはMIR2キャッシュのヒット時に、すでに頼っている性質である。

## 検証

- ADR 0015の「semanticとoptimizedの分離」のテストを通す。ロード直後に `semantic_ir` を読むテストは、作り直しを経由するようになる。
- 変更の前後で、wardite-benchesのWASIサンプルとruby.wasmの、semantic MIR・optimized MIR・bytecodeのダイジェストが一致することを確かめる。[ADR 0015](0015-efflorescence-selective-inline-snapshots.md) が使った正規化スクリプト（[mir_generation_digest.rb](../../test/support/mir_generation_digest.rb)）を使う。
- `bundle exec rake test`、`bundle exec rake check`、`make spinel-test RUBY="bundle exec ruby"`、`bundle exec rake parity` を実行する。

## 計測と受け入れ条件

[ADR 0018](0018-efflorescence-real-workload-measurement.md) の手順と条件に従う。一次指標は、ロードとMIR準備の時間（`WARDITE_TRACE` の `load_from_buffer`）とRSSである。1と2を別々に計測し、それぞれ短縮を確認できたものを採用する。
