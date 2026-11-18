# ADR 0018の実装とベースライン

[ADR 0018](adr/0018-efflorescence-real-workload-measurement.md) の計測手順を実装し、ADR 0019〜0022の比較に使うベースラインを取った。ベースラインの計測では、wardite-benchesの全15ケースで、出力がWasmtimeとiwasmに一致した。

## 実装した変更

Wardite：

- WASIのコマンドでも、`--mir-profile` を指定すると `Metrics#report` を標準エラーに出す。`_start` が戻ったときと、`proc_exit` で終わったときの両方で出す。Spinel版の `exit` も `ensure` を通ることを確かめた。
- `Metrics#opcode_report` を足した。実行したopcodeごとに `opcode 名前 回数` の行を、opcodeの番号順に出す。CLIは、`--invoke` とWASIのどちらでも `report` の次にこれを出す。`report` の行は変えていない。

wardite-benches：

- `script/compare` は、`script/run` を経由せずに `build/wardite --new-engine` を直接起動する。`--bench` の計測から、シェルの起動時間が除かれる。
- `script/fixtures` は、データを16倍にした `data-4m.bin` と `data-4m.b64`、画像の一辺を4倍にした `rgb-1024.png`、空の `empty` も作る。
- `script/build` は、Warditeをビルドしたときの `git describe` と `spinel --version` を `build/wardite.version` に書く。
- `script/baseline.sh` は、各ケースで結果を照合してから3つのエンジンをhyperfineで測る。WASIのケースでは、`WARDITE_TRACE` によるロード時間と、`--mir-profile` によるMIR命令の実行回数も残す。

## 計測の条件

ADR 0018を書いた後に、mainに [PR #53](https://github.com/udzura/wardite/pull/53) が入り、CIのSpinelの固定版が `58ee636` から `a2aa052` に上がった。ベースラインは、この時点のmainで取り直した。

- Wardite：`v1.2.2-10-g5c96407-dirty`。mainの `5c96407` に、この変更（`--mir-profile` の出力だけ）を加えた作業ツリーでビルドした
- Spinel：`spinel 2026.10.25+6092 (a2aa05227) [apple clang 21.0.0 (cc)]`、`-O2`、既定の整数overflow検査
- wardite-benches：`1155333-dirty`。`1155333` に、この変更を加えた作業ツリー
- マシン：Apple M3 Pro、macOS 26.6.2
- 比較の相手：iwasm 2.4.5 の `--interp`、wasmtime 28.0.0 (2e584e841 2024-12-20)
- 計測：hyperfine 2.0.0
- WasmのSHA-256は生値のJSONに記録した

時間は、各エンジンを2回ウォームアップした後の9回の中央値である。Warditeのロードは、`WARDITE_TRACE` の `load_from_buffer` を9回取った中央値である。RSSは、hyperfineが測った9回の最大値である。

## ベースライン

| ケース | Wardite | うちロード | WarditeのRSS | Wasmtime | iwasm | iwasmとの比 | MIR命令の実行回数 |
|---|---:|---:|---:|---:|---:|---:|---:|
| `xorshift`（WAT、1億回） | 2.386 s | — | 6.1 MiB | 268.1 ms | 915.4 ms | 2.6 | — |
| `xorshift`（Rust、1億回） | 1.597 s | — | 6.2 MiB | 446.6 ms | 1.285 s | 1.2 | — |
| `splitmix64`（1,000万回） | 1.561 s | — | 6.1 MiB | 22.2 ms | 123.1 ms | 12.7 | — |
| `mandelbrot_f32`（200×150、100回） | 2.321 s | — | 7.8 MiB | 15.6 ms | 23.9 ms | 97.1 | — |
| `mandelbrot_f64`（同上） | 2.367 s | — | 7.9 MiB | 14.6 ms | 22.3 ms | 106.3 | — |
| `monte_carlo_pi`（100万点） | 2.458 s | — | 7.6 MiB | 14.6 ms | 55.4 ms | 44.3 | — |
| `crc8_stream`（16 MiB） | 531.7 ms | — | 6.0 MiB | 48.8 ms | 82.9 ms | 6.4 | — |
| `crc8_stream`（16 MiB、grow後） | 657.3 ms | — | 8.2 MiB | 48.4 ms | 83.7 ms | 7.8 | — |
| Base64 encode、空 | 41.3 ms | 33.4 ms | 52.6 MiB | 14.4 ms | 12.3 ms | 3.3 | 2,731 |
| Base64 encode、256 KiB | 93.8 ms | 29.9 ms | 60.8 MiB | 15.6 ms | 16.6 ms | 5.7 | 4,322,082 |
| Base64 encode、4 MiB | 838.3 ms | 28.8 ms | 117.0 MiB | 44.6 ms | 75.1 ms | 11.2 | 69,041,163 |
| Base64 decode、256 KiB | 90.3 ms | 31.0 ms | 58.7 MiB | 18.5 ms | 16.9 ms | 5.3 | 4,934,288 |
| Base64 decode、4 MiB | 759.4 ms | 28.5 ms | 95.2 MiB | 52.8 ms | 78.2 ms | 9.7 | 78,828,412 |
| PNG、256×256 | 98.9 ms | 61.5 ms | 106.4 MiB | 15.4 ms | 18.2 ms | 5.4 | 3,779,456 |
| PNG、1024×1024 | 417.2 ms | 57.5 ms | 114.6 MiB | 19.2 ms | 62.9 ms | 6.6 | 54,437,427 |

i32だけのループ（`xorshift`）はiwasmの1.2〜2.6倍で、i64を使う `splitmix64` は12.7倍、浮動小数点を使うものは44〜106倍だった。WASIのサンプルは5.3〜11.2倍、バイト単位の読み出しが中心の `crc8_stream` は6.4〜7.8倍だった。

既定サイズの入力では、ロードとMIR準備がBase64で約30 ms、PNGで約62 msかかり、プロセス全体の3分の1（Base64）から6割（PNG）にあたる。16倍の入力では、ロードとMIR準備以外がBase64で96〜97%、PNGで86%を占める。

WarditeのRSSは、空の入力のBase64で52.6 MiB、PNGで106〜115 MiBだった。ADR 0018の予備計測（Wardite `5baaf38`、Spinel `58ee636`）より、空の入力で6.1 MiB、4 MiBのencodeで32.2 MiB大きい。予備計測とは、Wardite、Spinel、encodeのゲスト（末尾のLFの追加）が違う。どれが原因かは調べていない。

既定サイズの入力で実行したMIR命令の内訳は次のとおりである。

| 入力 | 実行回数の多い命令（全命令に対する割合） |
|---|---|
| Base64 encode、256 KiB | `I32_ADD` 21.0%、`COPY` 10.7%、`I64_SHR_U` 10.1%、`I32_LOAD8_U` 8.1%、`I32_STORE8` 8.1%、`I32_AND` 7.1% |
| Base64 decode、256 KiB | `COPY` 25.1%、`I32_ADD` 16.4%、`I64_OR` 9.7%、`I64_SHL` 8.9%、`BR_IF` 7.5%、`I32_LOAD8_U` 7.1% |
| PNG、256×256 | `I32_ADD` 30.3%、`COPY` 23.0%、`I32_LOAD8_U` 10.7%、`I32_STORE8` 7.3%、`BR_IF` 6.1%、`I32_MUL` 5.2% |

生値は [real-workloads-baseline-2026-11-18.json](../benchmark/results/real-workloads-baseline-2026-11-18.json) にある。hyperfineの各回の時間とRSS、ロード時間の各回の値、WASIのケースのopcodeごとの実行回数を含む。

## 再計測の手順

wardite-benchesのルートで、CIの `SPINEL_REF` と同じSpinelを `SPINEL` に指定する。

```sh
SPINEL=/path/to/spinel script/build
script/fixtures
script/baseline.sh build/results/after
```

前後を比べるときは、`build/wardite` を別名でコピーしてから、もう一方をビルドする。そのうえで、2つのバイナリを1回のhyperfineに並べ、順序を入れ替えてもう1回測る（[ADR 0018](adr/0018-efflorescence-real-workload-measurement.md)）。
