# ADR 0015 の実装計測

## キャッシュなしのロード

ADR 0014 マージ後の `33f0852` と、ADR 0015 の A/B/C を適用した `9bdb1fb` を比較した。Apple M3 Pro、macOS 27.2.1 arm64、Spinel `01a5d1bea`、`--strict-require -O2`、既定の最適化と整数オーバーフロー検査を使用した。各計測の最初にウォームアップを1回行い、変更前後を交互に独立プロセスで実行した。ビルドと時間計測は分けた。

| 入力・指標 | 試行数（各） | 変更前の中央値（最小–最大） | 変更後の中央値（最小–最大） |
|---|---:|---:|---:|
| Ruby 3.4.2 Wasm、ロード（秒） | 10 | 3.133 (3.047–3.150) | 2.565 (2.555–2.635) |
| Ruby 3.4.2 Wasm、ピーク RSS（GiB） | 10 | 5.833 (5.832–5.834) | 5.239 (5.237–5.239) |
| Ruby 4.0.9 Wasm、CLI のロード（秒） | 5 | 3.684 (3.653–3.741) | 2.946 (2.930–2.975) |
| Ruby 4.0.9 Wasm、CLI 起動から終了（秒） | 5 | 4.176 (4.138–4.229) | 3.428 (3.410–3.459) |
| Ruby 4.0.9 Wasm、ピーク RSS（GiB） | 5 | 6.893 (6.891–6.893) | 6.539 (6.530–6.539) |

3.4.2 のロードは18.1%、4.0.9 の CLI 起動から終了までは17.9%短縮した。3.4.2 はフェーズ計測なしの worker。4.0.9 は `--disable-gems -e 'puts RUBY_VERSION; puts 6*7'` を実行し、全試行で出力を確認した。入力は ADR 0014 と同じ2ファイルを使用した。 [入力とビルド条件](efflorescence-mir-build-validation-and-decoding-results.md)

## 段階別の最適化時間

Ruby 3.4.2 Wasm の詳細計測。各5回の中央値（最小–最大）。時間は各メソッドの内側の呼び出しを含む。

| 段階 | リビジョン | 最適化（秒） | `IR#copy` 合計（秒） | `IR#copy` 回数 |
|---|---|---:|---:|---:|
| 変更前 | `33f0852` | 0.957 (0.931–0.984) | 0.949 (0.922–0.976) | 2 |
| A constant 判定 | `3e1d9d4` | 0.647 (0.643–0.681) | 0.639 (0.635–0.673) | 2 |
| B snapshot 選別 | `57f1587` | 0.492 (0.489–0.504) | 0.484 (0.481–0.496) | 1 |
| C caller のスキップ | `9bdb1fb` | 0.491 (0.488–0.537) | 0.483 (0.480–0.529) | 1 |

最適化の時間は48.7%短縮した。C の効果はインライン化の時間と `Rewrite` の個数で確認した。Ruby 3.4.2 で B → C のインライン化は 0.765 ms → 0.579 ms、CALL がない `i32-chain-8192` では 0.237 ms → 0.043 ms。256個の CALL を持つ `inline-dense` のロード中央値は、フェーズ計測なしで前後 1.15 ms → 1.14 ms だった（各30回）。

## Function コピーの単体計測

各条件で前後10試行。1 Function のコピー当たりに換算した中央値（ms）。タイマーにはコピーした register と constant の配列を照合する時間を含む。

| register 数 | constant 数 | Spinel 変更前 → A | CRuby 変更前 → A |
|---:|---:|---:|---:|
| 512 | 128 | 0.044 → 0.009 | 0.237 → 0.077 |
| 8,192 | 0 | 0.119 → 0.113 | 1.129 → 1.054 |
| 8,192 | 128 | 0.683 → 0.112 | 3.980 → 1.070 |
| 8,192 | 4,096 | 13.335 → 0.123 | 68.728 → 1.307 |
| 8,192 | 8,192 | 17.004 → 0.132 | 91.267 → 1.556 |

8,192 register、constant なしのプロセスのピーク RSS 中央値は、Spinel で 6.19 → 6.98 MiB、CRuby で 24.01 → 25.61 MiB。bitmap はコピーごとの一時配列。回帰テストで constant リストの全要素を1回ずつ走査し、引数と local 以降の register を1回ずつ再構築し、constant リストへの `include?` が0回であることを確認した。

## コピー量と割り当て

Ruby 3.4.2 Wasm の CRuby 診断。最適化が最初に作る独立コピーを維持し、インライン化中に作る snapshot を計数した。

| 段階 | snapshot の関数 | 命令 | register | `Rewrite` を作った caller | 実際に展開した caller | 最適化内の割り当て |
|---|---:|---:|---:|---:|---:|---:|
| 変更前 | 8,161 | 2,172,837 | 1,383,608 | 292 | 5 | 9,947,309 |
| A | 8,161 | 2,172,837 | 1,383,608 | 292 | 5 | 9,963,632 |
| B | 169 | 176 | 413 | 292 | 5 | 4,635,852 |
| C | 169 | 176 | 413 | 5 | 5 | 4,628,476 |

B と C の snapshot は適格集合と一致した。最適化内の割り当ては変更前から53.5%減った。`inline-dense` では適格な1関数をコピーし、変更後の `Rewrite` は実際に展開する1 caller のみ。inline 無効時は `IR#copy` が1回、snapshot と `Rewrite` は0回だった。CRuby のピーク RSS は、診断と分けた Ruby 3.4.2 Wasm の前後各2試行で 1.62 → 1.40 GiB。

## 小入力とゲスト実行

i32、i64、float、memory、call、EH と i32-chain（256～8192）のキャッシュなしロードを前後各30回測った。中央値の変化は −8.6%～+0.3%。`inline-dense` の詳細計測では B と C のインライン化はいずれも35 µsだった。

ゲスト実行部分を前後各15回測った中央値は `inline_mix` が 21.282 → 21.333 ms、`call_mix` が 21.334 → 21.374 ms。すべての試行で出力 checksum が一致した。

## 同値性とキャッシュ

- 小入力10件で、既定・全無効・各最適化の単独無効を profiling の有無と組み合わせ、各16設定で前後を比較した。Ruby 3.4.2 と 4.0.9 Wasm も既定設定で比較した。命令 tuple、semantic/optimized MIR、lowering 後の bytecode と side table がすべて一致した。 [正規化スクリプト](../test/support/mir_generation_digest.rb)
- `inline-dense` の MIR2 ファイルは Spinel の前後でバイト単位で一致し、変更前に生成したキャッシュを変更後にヒットさせて実行した。
- 不正な直接 CALL は、snapshot が空でも従来の `Wardite::EvalError` になる。手書きの不正 MIR で他のローカルパスを無効にしたケースでは、展開しない関数の範囲外 branch target が変更後は検証まで残り、`TranslationError` になった。旧版の `Rewrite` は正の範囲外値に `IndexError` を出し、負の値 `-2` は負添字として有効な PC に変換していた。
- `bundle exec rake test` と `bundle exec rake check` が成功。`bundle exec rake parity` は CRuby・Spinel 各436 fixture、各428件の stack 比較が通った。
- Ruby 4.0.9 Wasm の `verify_ruby_wasm.rb` を Spinel バイナリと `WARDITE_VERIFY_MIR_CACHE=1` を指定して実行し、`-e`、`require_relative`、`exit 7` の出力・終了コードを Wasmtime と照合した。
- `make spinel-test RUBY="bundle exec ruby"` の85件がすべて成功した。MIR2 の eager/lazy 復元、inspection、snapshot、WASI を含む。

## 再現

各リビジョンのソースと別々の出力ディレクトリで worker を作る。ロード全体に `none`、段階別の時間に `detail` を指定する。RSS は `/usr/bin/time -l` の最大常駐サイズ。CRuby 4.0.9 の YJIT は無効。

```sh
ruby "$source_dir/benchmark/prepare_mir_generation_profile.rb" "$build_dir" none
spinel -I "$build_dir/lib" --strict-require -O2 \
  "$build_dir/mir_generation_worker.rb" -o "$build_dir/worker"

RSS=1 RUNS=10 ruby benchmark/compare_mir_generation_builds.rb \
  before="$before_none" after="$after_none" -- "$ruby_wasm_3_4_2"
RSS=1 RUNS=5 ruby benchmark/compare_mir_generation_builds.rb \
  before="$before_detail" A="$stage_a" B="$stage_b" C="$stage_c" -- "$ruby_wasm_3_4_2"
ruby -I"$source_dir/lib" benchmark/profile_inline_snapshots.rb "$ruby_wasm_3_4_2"
MIR_GENERATION_REVISION="$revision" ruby -I"$source_dir/lib" \
  benchmark/profile_mir_generation_allocations.rb "$ruby_wasm_3_4_2" "$allocations_json"
```

単体計測は `benchmark/mir_copy_worker.rb` を各リビジョンのライブラリで実行または Spinel ビルドし、register 数、constant 数、1試行あたりのコピー回数を渡す。`inline-dense` と `i32-chain` は `benchmark/generate_mir_generation_fixtures.rb` で生成する。ゲスト実行は `benchmark/optimization_worker.rb` で `i32_mix.wasm` の `inline_mix` と `call_mix` をそれぞれ引数 `1000000 123` で計測した。

各試行の時間、RSS、入力の SHA-256、構造カウンター、割り当て数、正規化した MIR のダイジェストを保存した。 [生データ](../benchmark/results/mir-generation-adr0015.json)
