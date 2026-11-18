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

全体時間が回帰閾値を超えたのは `mandelbrot-f32` で、正順は1.6%、逆順は1.5%遅くなった。今回はWASIのロード時間とRSSの改善を優先し、この回帰を許容してレビューに進める。初版にあった `splitmix64` の回帰は解消した。

### 正しさの検証

- wardite-benchesの全15ケースで `script/compare --iwasm` が一致した。WASI全7ケースの `--mir-profile` は合計と全opcodeの内訳が同じWasmを使った変更前と一致した。
- Base64、PNG、Ruby 3.4.2の `ruby.wasm`（SHA-256 `1ac460e944a54c17529aa05e6cad4575aab6d3d2466745f935237f7a46351e98`）で、既存の `mir_generation_digest.rb` による変更前後のダイジェストが一致した。プロファイル有効・無効の両方でsemantic IR、検査用optimized IR、実行用IRのbytecodeと副表を照合した。
- `bundle exec rake test` は316件、うちネイティブ用87件は `make spinel-test RUBY="bundle exec ruby"` で別途全件成功した。`bundle exec rake check` は型エラーなし。`WARDITE_VERIFY_MIR_CACHE_PARITY=1 bundle exec rake parity` はCRuby・Spinelともに436 fixtureの実行とMIR2復元を確認した。

## ADR 0020 の再計測（2026-11-18）

[ADR 0020](adr/0020-efflorescence-inline-i64-bit-operations.md) の対象は、i64 のビット演算・比較・シフト・回転と整数幅の変換の計25命令。Spinel の生成Cで、シフト・回転の補助関数の引数と戻り値はすべて `sp_int` になった。検証済みのレジスタは `fetch` で読み、シフト量は下位6ビットを使う。

Wardite は main `5f461c4` と実装 `b949062`、wardite-benches は `f07c454`。Apple M3 Pro、macOS 27.2.1、Spinel `a2aa05227` の `-O2` と既定の整数overflow検査で比較した。ADR 0018 の初回記録とはRust製Wasmのハッシュが異なるため、両バイナリで同じWasmと入力を使ってベースラインを取り直した。

表はプロセス全体の実行時間の中央値。hyperfine 2.0.0 の `-N` で各バイナリを2回ウォームアップして9回測り、逆順でも繰り返した。各セルは main → 実装の順。入力、WasmのSHA-256、実行引数、順序別の全サンプルと最大RSSは[計測JSON](../benchmark/results/adr0020-i64.json)に記録した。

| ケース | mainを先に測定 (ms) | 実装を先に測定 (ms) |
|---|---:|---:|
| xorshift-wat | 1789.46 → 1798.84 (+0.5%) | 1811.69 → 1806.17 (-0.3%) |
| xorshift | 1210.92 → 1202.06 (-0.7%) | 1219.34 → 1209.56 (-0.8%) |
| splitmix64 | 1165.36 → 633.45 (-45.6%) | 1165.87 → 642.64 (-44.9%) |
| mandelbrot-f32 | 1716.20 → 1700.52 (-0.9%) | 1703.66 → 1696.44 (-0.4%) |
| mandelbrot-f64 | 1698.65 → 1706.60 (+0.5%) | 1711.40 → 1727.36 (+0.9%) |
| monte-carlo-pi | 1790.82 → 1679.52 (-6.2%) | 1827.34 → 1683.66 (-7.9%) |
| crc8-stream | 397.67 → 401.55 (+1.0%) | 394.95 → 397.75 (+0.7%) |
| crc8-stream-grown | 493.78 → 477.97 (-3.2%) | 495.60 → 475.87 (-4.0%) |
| base64-encode-empty | 25.84 → 25.73 (-0.4%) | 25.35 → 25.50 (+0.6%) |
| base64-encode | 64.55 → 52.76 (-18.3%) | 67.18 → 53.23 (-20.8%) |
| base64-encode-4m | 649.03 → 419.62 (-35.3%) | 638.38 → 414.07 (-35.1%) |
| base64-decode | 63.88 → 46.77 (-26.8%) | 60.78 → 48.19 (-20.7%) |
| base64-decode-4m | 569.03 → 360.47 (-36.7%) | 563.53 → 360.29 (-36.1%) |
| png | 66.48 → 66.35 (-0.2%) | 66.59 → 66.35 (-0.4%) |
| png-1024 | 315.35 → 309.87 (-1.7%) | 314.98 → 311.10 (-1.2%) |

16倍入力のBase64は、encode・decodeともに両順で35%以上短縮し、中央値の差は変更前の標準偏差の10倍を超えた。ADR 0018初回の中央値はencode 838.3 ms、decode 759.4 msだった。今回の改善率は同一ゲストを使った直前のmainとの比較から算出した。

既定サイズのBase64もencodeで18〜21%、decodeで21〜27%短縮した。数値ケースでは `splitmix64` が45%前後、`monte-carlo-pi` が6〜8%短縮した。全15ケースでWasmtime・iwasmと出力が一致した。

初回に回帰閾値を超えたのは `crc8-stream` の正順だけで、3.88 ms増（+1.0%、変更前の2.04標準偏差）だった。同じバイナリで各31回の追加計測を行うと、正順は395.25 → 399.91 ms（+1.2%、1.35標準偏差）、逆順は415.06 → 403.11 ms（−2.9%）となり、両順とも閾値内だった。初回と追加計測は別々にJSONに収録した。

## ADR 0021 の段階別比較（2026-11-18）

[ADR 0021](adr/0021-efflorescence-optimize-real-functions.md) の準備段階1・2は、生成コードの一致とテストの成功で判定した。副表に残るCOPYを保つ修正前には4つの回帰テストがすべて失敗し、修正後はすべて成功した。Base64、PNG、i32ベンチ、Ruby 3.4.2のWasmでデコード結果・semantic MIR・実行用MIRのダイジェストがmainと一致した。段階2の変更はparityランナーだけである。

| 段階 | PR | ビルド内容 |
|---|---|---|
| 基準 | [#57](https://github.com/udzura/wardite/pull/57) マージ後のmain | `cbb0664` |
| 1 | [#58](https://github.com/udzura/wardite/pull/58) | 副表の読み出しを生存解析に含める |
| 2 | [#59](https://github.com/udzura/wardite/pull/59) | 全無効・既定の両構成でparityを実行する |
| 3 | [#60](https://github.com/udzura/wardite/pull/60) | `3f1172a`、128命令までのstore関数を対象にする |
| 4 | [#61](https://github.com/udzura/wardite/pull/61) | `a458739`、同じ上限で動的呼び出しを持つ関数を含める |
| 5 | [#62](https://github.com/udzura/wardite/pull/62) | `db5a180`、i64を含め、準備コストに応じて対象関数とcopyパスの範囲を調整する |
| 6 | [#63](https://github.com/udzura/wardite/pull/63) | `13410da`、段階5の条件でfloat関数を含める |

段階5以降、従来から対象だったi32関数は全パスを使う。新しく対象となった関数は16命令以下なら全パス、17〜128命令なら呼び出しを含まないループがある場合、129〜1,536命令ならそのループが64命令以上の場合に最適化する。16命令を超える対象でcopyパスが行うのは、結果を直後のCOPYの宛先へ直接書く変換である。これには副表の読み出しを含む全関数の使用回数と分岐先の検査を使う。EH関数とインライン展開のcallee側は従来の除外を維持した。生成コードが変わる段階3〜6でMIR2のコード版を1ずつ上げた。

### 実行したMIR命令数

Spinelの `--mir-profile` で取得した動的な命令数。速度計測は計装を外して別に行った。全15ケースのopcode別カウントと公開時点で測定済みの実行時間は[計測JSON](../benchmark/results/adr0021-optimizer.json)に収録した。

| WASIケース | main | 段階3 | 段階4 | 段階5 | 段階6 |
|---|---:|---:|---:|---:|---:|
| base64-encode-empty | 2,740 | 2,631 | 2,626 | 2,638 | 2,638 |
| base64-encode | 4,322,095 | 4,321,849 | 4,321,829 | 3,885,040 | 3,885,040 |
| base64-encode-4m | 69,041,176 | 69,040,890 | 69,040,866 | 62,050,498 | 62,050,498 |
| base64-decode | 4,934,301 | 4,933,919 | 4,933,898 | 3,972,806 | 3,972,806 |
| base64-decode-4m | 78,828,425 | 78,828,006 | 78,827,981 | 63,448,963 | 63,448,963 |
| png | 3,777,248 | 3,546,710 | 3,546,681 | 3,119,683 | 3,119,683 |
| png-1024 | 54,413,537 | 51,130,112 | 51,130,081 | 44,309,090 | 44,309,090 |

16倍のBase64 encodeで `COPY` は7,342,460 → 351,789回、`I32_ADD` は14,506,254 → 6,641,832回になった。decodeではそれぞれ19,750,763 → 4,371,311回、12,933,462 → 5,942,794回だった。PNG 1024では12,563,900 → 2,461,607回、17,541,431 → 9,580,270回に減った。

WASIの2本のゲストはfloat関数を使わず、段階5・6でWASI全7ケースのopcode別回数は一致した。段階6で変化したのは数値ベンチで、mandelbrot-f32は14,017,517 → 10,150,898命令、mandelbrot-f64は14,084,730 → 10,177,721命令、monte-carlo-piは41,000,011 → 31,000,009命令となった。

### プロセス全体の速度

Apple M3 Pro、macOS 27.2.1、Spinel `a2aa05227`、`-O2` と既定の整数overflow検査、wardite-benches `f07c454`。全段階で同じゲスト・入力を使用した。ケースごとにhyperfine 2.0.0の `-N` でmain → 3 → 4 → 5 → 6の順と逆順を測った。各バイナリを2回ウォームアップし、9回の中央値を比較した。表の各セルはmain → 段階6の時間。JSONには測定済みの各段階の時間・最大RSS、入力のハッシュ、引数も含めた。

| ケース | 正順 (ms) | 逆順 (ms) |
|---|---:|---:|
| splitmix64 | 901.65 → 693.16 (-23.1%) | 897.86 → 697.21 (-22.3%) |
| mandelbrot-f32 | 2479.27 → 2347.13 (-5.3%) | 2437.69 → 2337.11 (-4.1%) |
| mandelbrot-f64 | 2460.07 → 2365.24 (-3.9%) | 2491.27 → 2367.97 (-4.9%) |
| base64-encode-empty | 38.84 → 42.47 (+9.3%) | 40.96 → 44.65 (+9.0%) |
| base64-encode | 74.92 → 78.11 (+4.2%) | 75.75 → 78.58 (+3.7%) |
| base64-encode-4m | 604.06 → 574.17 (-4.9%) | 597.80 → 608.75 (+1.8%) |
| base64-decode | 70.36 → 70.85 (+0.7%) | 70.35 → 70.66 (+0.4%) |
| base64-decode-4m | 517.93 → 463.40 (-10.5%) | 520.05 → 456.20 (-12.3%) |
| png | 102.43 → 107.17 (+4.6%) | 106.09 → 109.08 (+2.8%) |
| png-1024 | 441.37 → 408.09 (-7.5%) | 447.01 → 407.30 (-8.9%) |

### 公開時点の判定

全15ケースで正しさと命令数を確認した。上表は公開時点で正順・逆順とも完了した10ケース。残るケースの速度判定は保留した。Base64 decodeの16倍入力は両順で約12%、PNG 1024も両順で短縮した。Base64 encodeの16倍入力は正順で速く、逆順で遅くなった。既定サイズのencodeとPNG、空入力では準備コストを含む全体時間が増えた。ADR 0021単体では全受け入れ条件の合格に至っていない。

ADR 0022の初回呼び出し時のMIR準備が入れば、実行しない関数の最適化にかかる時間を省ける可能性がある。併用時の実測は今後の比較対象とする。

### 動作確認

- store・動的呼び出し・i64・floatの各段階で、wardite-benches全15ケースの結果をWasmtimeおよびiwasmと照合した。WASIは出力バイト列、数値はビット列が一致した。
- 段階1〜6のCRuby・Spinelで構成マトリクスを通した。段階2〜6の `rake parity` では、両ランタイムで436 fixtureを既定・全無効の両構成で実行し、各構成でMIR2の作成・復元も検証した。
- Ruby 4.0.9 Wasm（SHA-256 `cb740da111ff6ef951f51fac3296466777cc7b9b48d327f8d8089edeae71a7a4`）で `-e`、`require_relative`、`exit 7` の標準出力と終了コードがWasmtimeと一致した。各段階3〜6のSpinelと最終版のCRubyを既定・全無効の両方で比較した。
- 最終版は `bundle exec rake test` 323件（ネイティブ用87件は別実行）、`bundle exec rake check` 型エラー0件、`make spinel-test RUBY="bundle exec ruby"` 87件成功。全無効で生成する実行用MIRのダイジェストはBase64・PNG・mandelbrot・splitmix64・Ruby 3.4.2の5入力でmainと一致した。

## ADR 0022とADR 0021を併用した結果

同じWasm・入力を使い、0021導入前のmain（`cbb0664`）、0021単体（`13410da`、#63の先端 `3990251` と実装は同一）、0021＋0022段階A（`e79000f`）を比較した。表の矢印はこの順序。Apple M3 Pro、macOS 27.2.1、Spinel `a2aa05227` の `-O2`、wardite-benches `f07c454` を使用した。

MIR2キャッシュとプロファイラは無効。hyperfine 2.0.0から各バイナリを直接起動し、正順と逆順のそれぞれでウォームアップ2回・計測9回を実行した。表は両順の中央値の平均。全体時間には初回呼び出しでの準備も含む。WASIのロード時間は `WARDITE_TRACE=1` の別プロセスで同じ回数測った。[実行順ごとの生値、入力SHA-256、出力照合](../benchmark/results/adr0022-lazy-mir.json)

| ケース | 全体 ms（main → 0021 → 併用） | 対main | 対0021 | ロード ms | ピークRSS MiB |
|---|---:|---:|---:|---:|---:|
| base64-encode-empty | 44.30 → 49.78 → 37.73 | -14.8% | -24.2% | 38.15 → 40.84 → 24.53 | 46.02 → 48.48 → 42.27 |
| base64-encode | 78.16 → 80.77 → 68.13 | -12.8% | -15.7% | 34.17 → 36.79 → 23.93 | 54.41 → 56.85 → 51.22 |
| base64-encode-4m | 600.66 → 588.68 → 565.11 | -5.9% | -4.0% | 29.97 → 32.74 → 21.09 | 109.35 → 113.02 → 106.26 |
| base64-decode | 68.20 → 69.78 → 60.98 | -10.6% | -12.6% | 32.99 → 36.13 → 23.64 | 51.95 → 54.35 → 49.42 |
| base64-decode-4m | 518.83 → 455.13 → 448.69 | -13.5% | -1.4% | 29.64 → 33.23 → 20.52 | 88.70 → 91.22 → 84.55 |
| png | 99.58 → 103.78 → 90.68 | -8.9% | -12.6% | 66.17 → 73.69 → 42.06 | 95.11 → 99.38 → 93.72 |
| png-1024 | 429.64 → 390.22 → 379.04 | -11.8% | -2.9% | 57.19 → 62.99 → 36.68 | 103.32 → 106.41 → 100.88 |
| xorshift-wat | 2545.23 → 2549.97 → 2555.06 | +0.4% | +0.2% | — | 6.33 → 6.38 → 6.31 |
| xorshift | 1701.92 → 1698.99 → 1698.58 | -0.2% | -0.0% | — | 6.42 → 6.49 → 6.44 |
| splitmix64 | 892.43 → 685.27 → 685.07 | -23.2% | -0.0% | — | 6.37 → 6.45 → 6.41 |
| mandelbrot-f32 | 2395.37 → 2306.19 → 2332.76 | -2.6% | +1.2% | — | 8.05 → 8.12 → 8.10 |
| mandelbrot-f64 | 2405.04 → 2317.46 → 2362.70 | -1.8% | +2.0% | — | 8.06 → 8.12 → 8.09 |
| monte-carlo-pi | 2349.91 → 2214.37 → 2285.22 | -2.8% | +3.2% | — | 7.90 → 7.95 → 7.95 |
| crc8-stream | 563.13 → 516.93 → 512.89 | -8.9% | -0.8% | — | 6.36 → 6.44 → 6.38 |
| crc8-stream-grown | 674.05 → 627.81 → 627.18 | -7.0% | -0.1% | — | 8.47 → 8.56 → 8.50 |

0021で起動時間が増えていた既定入力のBase64 encode・PNGは、併用すると0021導入前のmainよりそれぞれ12.8%、8.9%短い。0021単体との比較でも、既定サイズのBase64 encode・decode・PNGはロード時間とRSSが両順で旧標準偏差の2倍を超えて減った。全体時間の中央値も両順で減ったが、encodeの逆順ではこの差が2倍に届かなかった。16倍の3入力は全体時間・RSSとも両順で低下した。

数値ベンチでは、0021単体比でmandelbrot-f32が1.2%、f64が2.0%、monte-carlo-piが3.2%遅くなった。monte-carlo-piは両順で0021の中央値＋2標準偏差を超えた。main比ではこの3件とも速い。xorshift-watの全体時間はmain比0.4%増で両順の退行閾値を超えた。小規模な数値ゲストの一部ではmain比のRSSにも数十KiBの増加がある。WASIの速度とメモリは改善したが、全ケースの無退行条件は満たしていない。

翻訳時間は同じ段階AのSpinelバイナリに計時だけを足し、既定入力で別途測った。Base64ではロード23.52 msのうち翻訳15.59 ms、PNGでは41.87 msのうち29.54 ms（各9回の中央値）。段階Bの判断には、ロード時の型検査だけにかかる時間と、実行対象を再翻訳するコストを合わせて測る必要がある。今回の実装は段階Aまでとした。

全15ケースをwardite-benchesの `script/compare --iwasm` で照合した（WASIは出力バイト列、iwasmの浮動小数点表示は有効数字7桁）。Base64・PNG・Ruby 3.4.2 Wasmではプロファイル有効・無効の両方で、全関数のbytecode・レジスタ・副表を含むダイジェストがeager版と一致した。キャッシュの形式・バージョンは従来と同じ。

### CLIでのキャッシュの選び方

CLI変更を含む `5f9ca01` でBase64 encode（256 KiB）のプロセス全体を別途計測した。各組で空の一時ディレクトリを作り、表の順に実行した。2組のウォームアップ後に9組を採取し、各回で標準出力のSHA-256を照合した。時間は標準出力のパイプ読み取りを含む中央値。

| オプション | キャッシュ状態 | 全体時間 |
|---|---|---:|
| 指定なし | ディスクキャッシュなし・遅延仕上げ | 63.1 ms |
| `--mir-eager` | ディスクキャッシュなし・全関数仕上げ | 72.8 ms |
| `--mir-cache DIR` | ミス・全関数仕上げと保存 | 81.3 ms |
| `--mir-cache DIR` | ヒット・呼んだ関数を復元 | 43.4 ms |

### 手元での再計測

wardite-benchesのルートから、3つのリビジョンを同じSpinelでビルドした実行ファイルの絶対パスを `MAIN`、`ADR21`、`STACK` に設定して実行する。下記はBase64 encodeの既定入力。逆順でも実行すると起動順の影響を確認できる。

```sh
guest=build/rust/wasm32-wasip1/release/examples/base64_codec.wasm
hyperfine -N --warmup 2 --runs 9 --input build/fixtures/data.bin \
  "$MAIN --new-engine -- $guest encode" \
  "$ADR21 --new-engine -- $guest encode" \
  "$STACK --new-engine -- $guest encode"
WARDITE_TRACE=1 "$STACK" --new-engine -- "$guest" encode < build/fixtures/data.bin > /dev/null
```
