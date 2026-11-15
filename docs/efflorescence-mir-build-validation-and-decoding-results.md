# ADR 0014 の実装計測

## Ruby 3.4.2 Wasm

PR #46 の SHA-256 `1ac460e944a54c17529aa05e6cad4575aab6d3d2466745f935237f7a46351e98` の入力を再利用した。Spinel のフェーズ計測なしの worker を前後で各5回起動し、ロード中央値は **11.50 秒 → 5.45 秒（52.6% 減）**、ピーク RSS の中央値は **6.94 GiB → 5.83 GiB**。範囲はロードが 11.43–11.61 秒と 5.44–5.48 秒、実行プロセス全体が 11.57–11.75 秒と 5.57–5.61 秒だった。

詳細計測の中央値（最小–最大）。デコード＋feature は試行ごとに足してから集計した。

| 段階 | リビジョン | ロード（秒） | register 検証（秒） | デコード＋feature（秒） | `FlowGraph` 構築 |
|---|---|---:|---:|---:|---:|
| 変更前 | `b29e29d` | 12.04 (11.73–12.30) | 4.430 (4.296–4.619) | 4.070 (3.958–4.112) | 8,161 |
| A レジスタ参照 | `59b867e` | 11.69 (11.61–12.43) | 3.757 (3.692–4.270) | 3.650 (3.586–3.668) | 8,161 |
| B ブロック CFG | `d7b6ca4` | 9.10 (8.94–9.66) | 1.139 (1.133–1.181) | 3.674 (3.579–3.843) | 0 |
| C byte デコード | `94e1ea5` | 6.02 (5.95–6.51) | 0.929 (0.918–0.967) | 1.437 (1.395–1.531) | 0 |
| D feature 情報 | `c5e490a` | 5.57 (5.54–6.04) | 0.934 (0.930–0.976) | 0.949 (0.922–1.067) | 0 |

B から非 EH の全 8,161 関数がブロック単位で検証される。D では 13,479 回のデコードで `DecodedBody` とブロック参照配列を作る。C → D でデコード単体の中央値は 0.880 秒 → 0.941 秒、feature 確認は 0.552 秒 → 0.008 秒。ピーク RSS の中央値は C から約 12 MiB 増えた。

## 小入力・EH

Spinel で前後各15回。i32、i64、float、memory、call と小さな EH のロード中央値は 14.7–25.8% 減。i32-chain の N=256/512/1024/2048/4096/8192 は 23.5–33.2% 減で、N=8192 は 138.1 ms → 105.6 ms。

EH の検証用に catch 付きの関数を512個生成した。計測した3段階で例外辺を含む `FlowGraph` が513回構築された。

| 段階 | ロード中央値（最小–最大、ms） | register 検証中央値（最小–最大、ms） | ピーク RSS 中央値（MiB） |
|---|---:|---:|---:|
| 変更前 | 303.2 (299.9–309.4) | 105.5 (103.7–107.8) | 255.6 |
| A | 292.8 (289.6–315.4) | 91.6 (90.6–98.5) | 202.8 |
| D | 204.6 (198.7–221.6) | 50.7 (48.8–56.0) | 201.3 |

## Ruby 4.0.9 の CLI 起動

Ruby の `3e93b23afc` を WASI SDK 25.0、Binaryen 133、16 MiB の Wasm スタックで再ビルドした。今回の SHA-256 は `1e6953362fd62c5e1dcd2bf461c65c924653e5d94777621bedfa5907277270c8`。フェーズ1の計測とは別の Wasm で、今回の前後比較には同じファイルを使った。 [Ruby Wasm のビルド手順](efflorescence-ruby-wasm-phase1.md)

Spinel CLI をキャッシュなしで前後各5回実行し、毎回 `4.0.9` と `42` を出力した。

| 指標 | 変更前の中央値（最小–最大） | 変更後の中央値（最小–最大） |
|---|---:|---:|
| コマンド開始から終了まで（秒） | 14.81 (14.68–14.91) | 7.08 (7.00–7.08) |
| `load_from_buffer`（秒） | 13.89 (13.78–13.96) | 6.32 (6.25–6.34) |
| ピーク RSS（GiB） | 9.42 (9.42–9.42) | 6.89 (6.89–6.89) |

`i32_mix` のゲスト実行部分を前後各15回測った。中央値は `inline_mix` が 30.83 ms → 30.79 ms、`call_mix` が 30.90 ms → 30.80 ms。いずれも checksum は一致した。

## CRuby の時間・RSS

CRuby 4.0.9 のフェーズ計測なし worker を前後各5回測った。Ruby 3.4.2 Wasm のロード中央値は 34.23 秒 → 25.35 秒、範囲は 33.77–35.56 秒と 24.68–26.27 秒。ピーク RSS の中央値は 1.74 GiB → 1.62 GiB。Ruby 4.0.9 Wasm のピーク RSS は 2.08 GiB → 1.99 GiB。こちらの経過時間は最大 563.98 秒を含むため、全試行を参考値として JSON に掲載した。

`eh-512` の各15回では、変更前・A・D の register 検証中央値がそれぞれ 296.1、187.2、193.7 ms、ピーク RSS の中央値が 62.8、63.5、62.9 MiB だった。

## CRuby の割り当て

各リビジョンの本体に同じ Vernier 診断を適用し、Ruby 3.4.2 Wasm のフェーズ内で割り当てた個数を比較した。

| フェーズ | 変更前 | A | B | C | D |
|---|---:|---:|---:|---:|---:|
| register 検証 | 30,862,889 | 17,326,494 | 3,485,239 | 3,485,239 | 3,485,239 |
| デコード | 22,246,281 | 22,246,281 | 22,246,281 | 9,222,827 | 9,249,790 |

A で型確認の割り当ては 4,563,725 個 → 46 個。B で検証全体は変更前から 88.7% 減った。D のデコードは C より 26,963 個増え、変更前から 58.4% 減った。

## 同値性・キャッシュ

- CRuby で正規化した命令 tuple、semantic MIR、optimized MIR と lowering 後の bytecode・side tables が前後で一致した。i32、i64、float、memory、call、EH を含む小入力8件では既定と各無効化設定を profiling の有無と組み合わせ、各16通りを比較した。Ruby 3.4.2 と 4.0.9 は既定で比較した。 [正規化スクリプト](../test/support/mir_generation_digest.rb)
- `eh-512` の MIR2 ファイルは Spinel の変更前後でバイト単位で一致し、旧バイナリが生成したキャッシュは変更後の CLI でヒットした。
- stack engine では、複数の feature エラーを含む1関数で EH のエラーが先になる場合がある。個別の不正入力の拒否と、配列や `Block` の公開後に行う全走査は回帰テストで確認した。
- `bundle exec rake test`、`bundle exec rake check`、`bundle exec rake parity`。parity は CRuby・Spinel 各436 fixture と各428件の stack 比較。
- `make spinel-test RUBY="bundle exec ruby"` は85件（MIR2、遅延復元、snapshot、WASI を含む）すべて成功。
- Ruby 4.0.9 Wasm の `verify_ruby_wasm.rb` を `WARDITE_SPINEL_BIN` と `WARDITE_VERIFY_MIR_CACHE=1` を指定して実行した。`-e`、`require_relative`、`exit 7` の出力と終了コードが Wasmtime、CRuby、Spinel で一致した。


## 再現

Apple M3 Pro、macOS 27.2.1 arm64、CRuby 4.0.9（YJIT 無効）と Spinel `01a5d1bea` を使用。全ビルドで `--strict-require -O2`、inline RBS と既定の整数オーバーフロー検査を維持した。各段階の本体は表のリビジョンと同じ。Wasm と最適化設定を固定し、MIR2 キャッシュを指定せず、各計測でウォームアップ1回の後、新しいプロセスを交互に実行した。ロード時間は `load_from_buffer` 内の経過時間。RSS は macOS の `/usr/bin/time -l` の最大常駐サイズ。ビルドと経過時間の計測は分けた。

各リビジョンのソースから別の出力ディレクトリに worker を生成する。主指標に `none`、フェーズと呼び出し回数の診断に `detail` を指定する。

```sh
ruby "$source_dir/benchmark/prepare_mir_generation_profile.rb" "$build_dir" none
spinel -I "$build_dir/lib" --strict-require -O2 \
  "$build_dir/mir_generation_worker.rb" -o "$build_dir/worker"

RSS=1 RUNS=5 ruby benchmark/compare_mir_generation_builds.rb \
  before="$before_none" after="$after_none" -- "$ruby_wasm_3_4_2"
RSS=1 RUNS=5 ruby benchmark/compare_mir_generation_builds.rb \
  before="$before_detail" A="$stage_a" B="$stage_b" C="$stage_c" D="$stage_d" -- "$ruby_wasm_3_4_2"
MIR_GENERATION_REVISION="$revision" ruby -I"$source_dir/lib" \
  benchmark/profile_mir_generation_allocations.rb "$ruby_wasm_3_4_2" "$allocations_json"
```

CRuby の経過時間と RSS は比較スクリプトに `RUNTIME=cruby` を指定する。スケーリング入力と EH の `eh-512` は `benchmark/generate_mir_generation_fixtures.rb` で生成する。ゲスト実行比較は前後で `benchmark/optimization_worker.rb` を同じ Spinel でビルドし、`i32_mix.wasm` の `inline_mix`、`call_mix` にそれぞれ `1000000 123` を渡す。Ruby 4.0.9 の CLI は `build/wardite --new-engine -- "$ruby_wasm_4_0_9" --disable-gems -e 'puts RUBY_VERSION; puts 6*7'` を `WARDITE_TRACE=1` で起動する。

比較元の調査と受け入れ条件は PR #46 を参照。各試行の時間・構造カウンター・RSS・fixture hash・CRuby 割り当てプロファイルは JSON に保存した。 [PR #46](https://github.com/udzura/wardite/pull/46) · [計測データ](../benchmark/results/mir-generation-adr0014.json)
