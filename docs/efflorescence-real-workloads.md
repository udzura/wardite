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

## ADR 0019 の再計測（2026-11-18）

Wardite `c48e371` と最終候補 `0710c91` を、Apple M3 Pro、macOS 27.2.1、Spinel `a2aa05227` の `-O2` と既定のoverflow検査で比較した。wardite-benches は `f07c454`。上のベースラインと同じ15ケースを使った。Rust製Wasm 7本は上の表とSHA-256が異なるため、今回の比較では変更前後で同一のWasmと入力を使い、変更前の値も取り直した。

### 変更を分けた計測

同じmainから、(1) store命令の判定だけをHashにしたもの、(2) semantic IRの複製を初回の検査まで遅らせたもの、(3) 両方を組み合わせたものをビルドした。表は各実験の順方向での中央値。RSSはプロセスごとの最大RSSの中央値。逆順の値と各回の生値も [計測JSON](../benchmark/results/adr0019-startup.json) に残した。

| 変更 | Base64 encode 256 KiB ロード | 同 RSS | PNG 256×256 ロード | 同 RSS |
|---|---:|---:|---:|---:|
| 表引きのみ | 21.70 → 20.67 ms | 58.75 → 58.95 MiB | 46.59 → 44.12 ms | 103.78 → 103.81 MiB |
| IR複製の遅延のみ（試作） | 23.01 → 20.78 ms | 58.75 → 54.33 MiB | 45.76 → 44.35 ms | 103.81 → 95.00 MiB |
| 両方（試作） | 21.52 → 19.88 ms | 58.75 → 54.42 MiB | 44.53 → 41.05 ms | 103.78 → 95.08 MiB |

表引きは `MEMORY_WIDTHS.merge(...)` でstore系の全opcodeを含むHashを作り、`STORE_CODES.include?(code)` を `key?(code)` に置き換えて測った。Base64とPNGでRSSの改善条件を満たさず、逆順ではロード時間の短縮も変更前の標準偏差の2倍を下回ったため見送った。

### Spinelビルドで見つかった数値ベンチの回帰

初版 `4561231` は、両順で `splitmix64` のプロセス全体が6.0〜6.6%遅くなった。正順のハードウェア命令数の中央値は287.50億 → 287.68億、CPUサイクルは43.50億 → 46.15億だった。arm64の逆アセンブルでは `execute_flat` が9,200命令から9,920命令に増え、変更前にあった `FramePool#acquire` への直接呼び出しが消えていた。

保存する宣言を定義する `Translator::ModuleSource` を専用ファイルに分け、VM定義の後で読み込んだ。Rubyの処理は同じだが、このSpinelビルドでは `execute_flat` が9,200命令に戻り、`FramePool#acquire` の直接呼び出しも戻った。この候補について全15ケースを再計測した。JSONの `before_file_split` が初版、`final` が分割後である。

### 最終版の比較方法

検査用IRの遅延再生成を実装した。cold loadでは、元のコードセクションと翻訳に必要な宣言を保存し、semantic IRをその場で最適化する。`semantic_ir`、`optimized_ir`、`dump_mir` の初回呼び出しでは、この入力から検査用IRを再構成する。ロード後にホストがStoreや関数本体を変更してもロード時のMIRを表示し、start関数を再実行しない。MIR2ヒットでは従来の関数単位の復元を使う。

全15ケースで、2つのバイナリをhyperfine 2.0.0の同じ呼び出しに並べ、各2回ウォームアップ後に9回計測した。順序を逆にして同じ手順を繰り返した。WASIのロードは別プロセスで `WARDITE_TRACE=1` の `load_from_buffer` を同じ順序・回数で測った。数値のケースではプロセス全体の時間、WASIでは全体の時間・ロード・RSSを比較する。以下の表の矢印は変更前から変更後への変化を表す。

たとえば、Base64 encode の比較は wardite-benches のルートで次のように再現できる。`BEFORE` と `AFTER` には各チェックアウトを同じSpinelでビルドしたバイナリの絶対パスを指定する。

```sh
guest=build/rust/wasm32-wasip1/release/examples/base64_codec.wasm
for order in forward reverse; do
  first=$BEFORE second=$AFTER
  if [ "$order" = reverse ]; then first=$AFTER second=$BEFORE; fi
  hyperfine -N --warmup 2 --runs 9 --input build/fixtures/data.bin \
    --export-json "encode-$order.json" \
    "$first --new-engine -- $guest encode" "$second --new-engine -- $guest encode"
done
```

| WASIケース | ロード 正順 (ms) | ロード 逆順 (ms) | RSS 正順 (MiB) | RSS 逆順 (MiB) |
|---|---:|---:|---:|---:|
| base64-encode-empty | 20.73 → 19.66 | 20.63 → 19.80 | 50.52 → 46.05 | 50.50 → 46.05 |
| base64-encode | 20.61 → 19.55 | 20.47 → 19.87 | 58.75 → 54.42 | 58.75 → 54.44 |
| base64-encode-4m | 20.53 → 19.64 | 20.48 → 19.71 | 114.88 → 109.38 | 114.89 → 109.38 |
| base64-decode | 20.21 → 19.57 | 20.27 → 19.47 | 56.20 → 51.98 | 56.22 → 51.97 |
| base64-decode-4m | 20.48 → 19.92 | 20.65 → 19.56 | 93.09 → 88.73 | 93.08 → 88.73 |
| png | 42.32 → 40.04 | 42.56 → 40.12 | 103.80 → 95.11 | 103.78 → 95.11 |
| png-1024 | 42.91 → 40.57 | 42.74 → 40.63 | 112.05 → 103.34 | 112.03 → 103.34 |

| ケース | プロセス全体 正順 (ms) | プロセス全体 逆順 (ms) |
|---|---:|---:|
| xorshift-wat | 1776.69 → 1773.93 | 1774.05 → 1774.76 |
| xorshift | 1181.62 → 1183.44 | 1181.25 → 1183.76 |
| splitmix64 | 1153.41 → 1150.77 | 1159.77 → 1146.68 |
| mandelbrot-f32 | 1642.62 → 1668.09 | 1643.04 → 1668.18 |
| mandelbrot-f64 | 1663.57 → 1665.91 | 1661.49 → 1662.35 |
| monte-carlo-pi | 1756.38 → 1744.17 | 1759.31 → 1743.40 |
| crc8-stream | 389.26 → 389.75 | 388.38 → 388.89 |
| crc8-stream-grown | 485.17 → 485.04 | 488.22 → 490.12 |
| base64-encode-empty | 24.41 → 23.55 | 24.47 → 23.51 |
| base64-encode | 63.57 → 61.55 | 63.67 → 61.46 |
| base64-encode-4m | 635.21 → 631.43 | 634.88 → 630.39 |
| base64-decode | 58.83 → 56.75 | 58.51 → 57.16 |
| base64-decode-4m | 558.82 → 558.69 | 559.19 → 558.83 |
| png | 65.39 → 62.73 | 64.99 → 62.46 |
| png-1024 | 306.26 → 305.56 | 305.81 → 304.49 |

### 判定

WASI全7ケースで両順ともロード時間の中央値が短くなり、RSSの差は全ケースで変更前の標準偏差の2倍を超えた。ロード時間の短縮幅が2標準偏差に届かなかったのは既定サイズのBase64 encodeの逆順だけだった。

全体時間が回帰閾値を超えたのは `mandelbrot-f32` で、正順は1.6%、逆順は1.5%遅くなった。初版にあった `splitmix64` の回帰は解消したが、ADR 0018の全条件を満たさないため採用を保留する。

### 正しさの検証

- wardite-benchesの全15ケースで `script/compare --iwasm` が一致した。WASI全7ケースの `--mir-profile` は合計と全opcodeの内訳が同じWasmを使った変更前と一致した。
- Base64、PNG、Ruby 3.4.2の `ruby.wasm`（SHA-256 `1ac460e944a54c17529aa05e6cad4575aab6d3d2466745f935237f7a46351e98`）で、既存の `mir_generation_digest.rb` による変更前後のダイジェストが一致した。プロファイル有効・無効の両方でsemantic IR、検査用optimized IR、実行用IRのbytecodeと副表を照合した。
- `bundle exec rake test` は316件、うちネイティブ用87件は `make spinel-test RUBY="bundle exec ruby"` で別途全件成功した。`bundle exec rake check` は型エラーなし。`WARDITE_VERIFY_MIR_CACHE_PARITY=1 bundle exec rake parity` はCRuby・Spinelともに436 fixtureの実行とMIR2復元を確認した。
