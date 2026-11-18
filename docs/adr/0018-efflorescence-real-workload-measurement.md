# ADR 0018: 現実のワークロードで高速化を計測する手順を定める

- **状態** 採用。実装し、ベースラインを記録した。[実装とベースラインの記録](../efflorescence-real-workloads.md)を参照。
- **日付** 2026-11-17
- **基準** Wardite 1.2.2 `5baaf38`、Spinel `58ee636`（CIの `SPINEL_REF`）、`-O2`、既定の整数overflow検査、[wardite-benches](https://github.com/udzura/wardite-benches/tree/286de8be5226a4b41dc8e1b597b6717d761e9156) `286de8b`
- **関連** [ADR 0017](0017-efflorescence-linear-memory-loads.md)、[ADR 0019](0019-efflorescence-startup-quick-wins.md)、[ADR 0020](0020-efflorescence-inline-i64-bit-operations.md)、[ADR 0021](0021-efflorescence-optimize-real-functions.md)、[ADR 0022](0022-efflorescence-lazy-function-build.md)

## 決定

ADR 0019〜0022の高速化は、wardite-benchesのWASIサンプルを主な指標にする。対象は、Base64のencodeとdecode、PNGのグレースケール変換である。数値計算のサンプル（`xorshift`、`splitmix64`、`mandelbrot`、`monte_carlo_pi`）は、回帰の確認に使う。

計測をそろえるために、次の5つを行う。

1. 入力を3つの大きさにし、起動と実行を分けて測る。
2. 計測したWasm、Spinel、マシンを毎回記録する。Spinelは、CIの `SPINEL_REF` と同じリビジョンを使う。
3. 時間は、Warditeのバイナリを直接起動して測る。
4. WASIのコマンドでも `--mir-profile` の結果を出し、opcodeごとの実行回数も出す。
5. この手順でベースラインを取り、記録する。

ADR 0019〜0022の「計測と受け入れ条件」は、この ADR の[受け入れ条件](#受け入れ条件)に従う。

## 背景

### 現実のワークロードではiwasmとの差が大きい

Wardite `5baaf38` を、バイナリを直接起動して計測した。WarditeはSpinel `58ee636` の `-O2` でビルドした。比較の相手はiwasm 2.4.5の `--interp` で、JITのWasmtime 28.0.0も同時に測った。マシンはApple M3 Pro、macOS 26.6.2。時間はhyperfine 2.0.0で2回ウォームアップした後の9回の平均、RSSは同じ計測の最大値である。ロードとMIR準備は、`WARDITE_TRACE` の `load_from_buffer` を9回取った中央値である。

| ケース | Wardite | うちロードとMIR準備 | WarditeのRSS | iwasm | iwasmとの比 |
|---|---:|---:|---:|---:|---:|
| `xorshift`（WAT、1億回） | 2.381 s | — | 6.1 MiB | 0.949 s | 2.5 |
| `xorshift`（Rust、1億回） | 1.604 s | — | 6.2 MiB | 1.384 s | 1.2 |
| `splitmix64`（1,000万回） | 1.603 s | — | 6.1 MiB | 0.139 s | 11.5 |
| `mandelbrot_f32`（200×150、100回） | 2.299 s | — | 7.8 MiB | 0.021 s | 109 |
| `mandelbrot_f64`（同上） | 2.398 s | — | 7.9 MiB | 0.024 s | 100 |
| `monte_carlo_pi`（100万点） | 2.475 s | — | 7.7 MiB | 0.056 s | 44 |
| Base64 encode、空 | 39.6 ms | 29.1 ms | 46.5 MiB | 11.2 ms | 3.5 |
| Base64 encode、256 KiB | 94.6 ms | 29.2 ms | 52.4 MiB | 16.3 ms | 5.8 |
| Base64 encode、4 MiB | 932.9 ms | 27.6 ms | 84.8 MiB | 87.1 ms | 10.7 |
| Base64 decode、256 KiB | 84.6 ms | 28.4 ms | 52.5 MiB | 14.6 ms | 5.8 |
| Base64 decode、4 MiB | 763.6 ms | 31.6 ms | 89.3 MiB | 79.4 ms | 9.6 |
| PNG、256×256 | 106.0 ms | 66.8 ms | 97.0 MiB | 18.9 ms | 5.6 |
| PNG、1024×1024 | 435.2 ms | 60.7 ms | 105.3 MiB | 63.3 ms | 6.9 |

i32だけのループは、iwasmの1.2〜2.5倍の時間で済む。i64を使うと11.5倍、浮動小数点を使うと44〜109倍になる。WASIのサンプルは5.6〜10.7倍である。

既定サイズの入力では、ロードとMIR準備がプロセス全体の時間の3割（Base64）から6割（PNG）を占める。WarditeのRSSは46〜105 MiBで、iwasmの10〜15 MiBより大きい。16倍の入力では、変換のループがほとんどの時間を占める。

WasmのSHA-256は、`base64_codec.wasm` が `3081b99a…63dc`、`png_grayscale.wasm` が `65ca6ba8…445e` である。

### 計測の条件をそろえないと値が変わる

計測の途中で、値を変える条件が3つ見つかった。

Warditeだけがシェルスクリプト経由で起動されていた。wardite-benchesの `script/compare --bench` は、Warditeを `script/run` 経由で起動し、Wasmtimeとiwasmはバイナリを直接起動する。`script/run` は `/bin/sh` のスクリプトで、macOSでは起動に約24 msかかる。上の表とは別に、空の入力でのBase64 encodeを2つの起動方法で続けて測ると、直接起動で47.2 ms、`script/run` 経由で71.2 msだった。`/bin/sh -c true` だけで13.3 msかかった。

手元のSpinelが古いと、MIR2キャッシュのヒットが失敗する。Spinel `6f1a2c259` でビルドしたWarditeは、キャッシュのヒット時に「IO::Buffer.for with a block ... is not supported」で止まった。ブロック付きの `IO::Buffer.for` は、Spinel `772b28126` で対応した。CIの `58ee636` でビルドし直すとキャッシュが動き、PNGのロードはミスで80 ms（書き込みを含む）、ヒットで3.1 msだった。キャッシュを使わない時間は、2つのSpinelでほぼ同じだった。

Wasmのビルドが違うと値が変わる。[ADR 0017](0017-efflorescence-linear-memory-loads.md) の計測では、256 KiBのBase64 encodeが全体で65 ms、ロードが22 msだった。このADRの計測では、同じ入力でロードが29.2 msだった。ADR 0017のWasmはRust nightly 1.100.0でビルドしていて、このADRのWasmとはRustのバージョンが違う。比べられるのは、SHA-256が同じWasmの値だけである。

### WASIのコマンドではMIR命令の実行回数が出ない

CLIは、`--invoke` で関数を呼んだときだけ `Metrics#report` を出力する（[cli.rb](../../lib/wardite/cli/cli.rb#L179)）。WASIの `_start` を実行する `start_wasi` は出力しない。`Metrics` はopcodeごとの回数（`opcode_counts`）を持っているが、`report` が出すのは合計だけである。

ADR 0019〜0022の調査では、CRubyで `mir_profile: true` を指定してロードし、終了時に `opcode_counts` を出すスクリプトを別に書いた。実行回数はランタイムに依存しないので、この方法で数えた値を各ADRに載せている。

## 計測の対象

| ワークロード | 入力 | 主に測るもの |
|---|---|---|
| `base64_codec encode` | 空（0バイト） | 起動、ロード、MIR準備 |
| `base64_codec encode` | `data.bin`（256 KiB） | 起動を含む既定の入力 |
| `base64_codec encode` | `data-4m.bin`（4 MiB、既定の16倍） | 変換のループ |
| `base64_codec decode` | `data.b64`（256 KiB）、`data-4m.b64`（4 MiB） | 既定の入力と、変換のループ |
| `png_grayscale` | `rgb.png`（256×256）、`rgb-1024.png`（1024×1024） | 既定の入力と、変換のループ |

16倍の入力と空の入力は、wardite-benchesの `script/fixtures` で生成できるようにする。16倍の入力は、既定の入力と同じ規則で、データを16倍にするか、画像の一辺を4倍にする。

## 計測する値

| 値 | 方法 | 使う場面 |
|---|---|---|
| プロセス全体の時間 | `hyperfine -N`。2回ウォームアップし、9回以上計測する。`--export-json` で中央値と生値を残す | すべての比較 |
| 最大RSS | 同じhyperfineの計測の `Memory` | ロードとMIR準備の比較 |
| ロードとMIR準備の時間 | `WARDITE_TRACE=1` の `load_from_buffer` を9回取った中央値 | ロードとMIR準備の比較 |
| MIR命令の実行回数 | `--mir-profile` のopcodeごとの回数 | 最適化パスの比較 |
| CPUのサンプル | macOSの `sample`（1 ms間隔）。入力を大きくして数秒動かす | 原因の調査 |

`--mir-profile` は計装したMIRを実行するので、時間の計測と同じ実行では使わない。実行回数は毎回同じ値になるので、1回で足りる。CPUのサンプルも、時間の計測とは別に取る。

変更の前後を比べるときは、前後のバイナリを1回のhyperfineに並べ、順序を入れ替えてもう1回測る。

## 変更

### Wardite

- `start_wasi` で、`--mir-profile` のときに `Metrics#report` を出す。`_start` が戻ったときと、`proc_exit` で終了するときの両方で出す。
- opcodeごとの回数を出すメソッドを `Metrics` に足し、CLIは `report` に続けてその結果を出す。`report` の1行目の形式は変えない。`dispatches=` で始まる行を、テスト（[efflorescence_mir_cache_test.rb](../../test/efflorescence_mir_cache_test.rb) など）が読んでいる。

Efflorescenceの `proc_exit` は `exit` を呼ぶ（[wasi.rb](../../lib/wardite/efflorescence/wasi.rb#L47)）。CRubyの `exit` は `SystemExit` を送出するので、`ensure` で出力できる。Spinelの `exit` が `ensure` を通るかを確かめる。通らない場合は、`proc_exit` で `exit` を呼ぶ前に出力する。

### wardite-benches

- `script/compare --bench` で、Warditeのバイナリを直接起動する。
- `script/fixtures` で、16倍の入力と空の入力を生成する。
- 計測用のスクリプトを足す。各ケースで、`script/compare` による結果の照合、hyperfineによる3エンジンの計測、`WARDITE_TRACE` によるロード時間の計測を行う。冒頭に、WarditeとSpinelのリビジョン、WasmのSHA-256、CPUを出力する。

## ベースラインの記録

背景の表は、wardite-benchesを変更する前に手元のスクリプトで取った値で、時間は平均である。wardite-benchesの変更の後、上の手順でWardite `5baaf38` とSpinel `58ee636` のベースラインを取り直す。結果は `docs/efflorescence-real-workloads.md` に、生値は `benchmark/results/` に置く。ADR 0019〜0022の実装記録は、このベースラインとの差を書き足す。

## 受け入れ条件

ADR 0019〜0022の各変更に共通する条件である。

- 結果が正しい：wardite-benchesの全ケースで、出力がWasmtimeと一致する。WASIのケースはバイト単位で、数値のケースはビット単位で比べる（`script/compare`）。
- 一次指標が改善する：各ADRが挙げた一次指標が、時間・RSSなら次の条件を満たす。順序を入れ替えた2回の計測の両方で、変更後の中央値が変更前より小さく、差が変更前の標準偏差の2倍より大きい。MIR命令の実行回数なら、変更後の回数が変更前より少ない。
- ほかのケースが悪化しない：一次指標以外のケースで、変更後の中央値が、変更前の中央値に標準偏差の2倍を足した値を超えない。
- 既存の検証が通る：`bundle exec rake test`、`bundle exec rake check`、`make spinel-test RUBY="bundle exec ruby"`、`bundle exec rake parity` を実行する。

MIR命令の実行回数を変える変更では、変更前後の回数をopcodeごとに記録する。

## 対象外

- Spinelを `--int-overflow=wrap` などの別の設定でビルドすること。Warditeは既定のoverflow検査で動かす（[efflorescence-ja.md](../efflorescence-ja.md)）。
- MIR2キャッシュを既定で有効にするかどうか。別のADRで判断する。
- 浮動小数点の演算の高速化。差は大きいが、対象のワークロードではほとんど使われない。
