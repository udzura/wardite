# ADR 0016 の実装計測

ADR 0015 マージ後の `1bce886` と ADR 0016 の実装 `5b4c0ca` を比較した。Apple M3 Pro、macOS 27.2.1 arm64、Spinel `01a5d1bea`、`--strict-require -O2` を使用した。整数オーバーフロー検査は既定のまま。CRuby 4.0.9 の YJIT は無効。各条件で前後を1回ずつウォームアップしたあと、独立プロセスで順序を交替して実行した。ビルドと計測は時間を分け、RSS は `/usr/bin/time -l` の最大常駐サイズを記録した。 [全試行と入力 SHA-256](../benchmark/results/mir-generation-adr0016.json)

## キャッシュなしの Ruby Wasm

Spinel で各10回の中央値（最小–最大）。Ruby 3.4.2 は内部タイマーを使わない worker。Ruby 4.0.9 は `--disable-gems -e 'puts RUBY_VERSION; puts 6*7'` を実行し、全試行で出力を照合した。

| 入力・指標 | 変更前 | 変更後 |
|---|---:|---:|
| Ruby 3.4.2 ロード（秒） | 2.629 (2.599–2.683) | 2.629 (2.607–2.661) |
| Ruby 3.4.2 ピーク RSS（MiB） | 5,364.3 (5,362.6–5,365.0) | 5,356.7 (5,354.9–5,356.9) |
| Ruby 4.0.9 CLI ロード（秒） | 3.023 (2.983–3.163) | 3.010 (2.992–3.047) |
| Ruby 4.0.9 CLI 起動から終了（秒） | 3.521 (3.474–3.658) | 3.510 (3.489–3.540) |
| Ruby 4.0.9 CLI ピーク RSS（MiB） | 6,695.1 (6,686.7–6,696.2) | 6,694.5 (6,694.2–6,694.6) |

詳細 worker で測った `propagate` の合計時間は3.4.2で 2.051 → 0.858 ms、4.0.9で 1.493 → 0.520 ms。3.4.2 の対象は8,161関数のうち292関数で、命令数では約0.16%。キャッシュなしの起動時間の差は試行間のばらつきに収まった。

## 人工 i32 関数のサイズ依存性

`i32-chain-N` は1関数内で加算とローカルへの書き戻しを N 回繰り返す。フェーズ別の計測は Spinel で各15回、CRuby で各5回。ロードは内部タイマーなしの Spinel で各30回。単位は ms で、中央値（最小–最大）を示す。

| N | Spinel `propagate` 変更前 → 変更後 | CRuby `propagate` 変更前 → 変更後 | Spinel ロード 変更前 → 変更後 |
|---:|---:|---:|---:|
| 256 | 0.173 (0.166–0.194) → 0.085 (0.082–0.094) | 3.252 (3.123–3.389) → 0.659 (0.641–0.679) | 0.843 (0.771–0.938) → 0.766 (0.725–0.842) |
| 512 | 0.429 (0.416–0.479) → 0.098 (0.092–0.120) | 11.367 (11.051–11.590) → 1.263 (1.225–1.281) | 1.546 (1.496–1.709) → 1.321 (1.253–1.431) |
| 1,024 | 1.487 (1.432–1.502) → 0.183 (0.180–0.205) | 41.753 (41.221–42.109) → 2.443 (2.429–2.496) | 3.332 (3.186–3.539) → 2.472 (2.419–2.568) |
| 2,048 | 5.394 (5.282–5.512) → 0.380 (0.371–0.412) | 160.789 (157.944–162.439) → 5.143 (4.892–5.175) | 8.303 (8.052–8.954) → 5.209 (5.030–6.053) |
| 4,096 | 20.605 (20.091–20.957) → 0.750 (0.730–0.805) | 627.596 (622.693–636.612) → 9.865 (9.657–10.019) | 22.271 (21.552–22.829) → 10.274 (9.790–11.239) |
| 8,192 | 80.235 (79.330–80.936) → 1.508 (1.446–1.590) | 2,493.840 (2,476.954–2,497.288) → 21.910 (21.481–22.018) | 70.226 (69.177–73.095) → 23.343 (22.059–24.388) |

N=8,192 で Spinel の `propagate` は98.1%、ロードは66.8%短縮した。N=4,096 から8,192で `propagate` の中央値は旧方式の3.89倍から2.01倍、CRuby では3.97倍から2.22倍になった。

N=8,192 の Spinel 詳細計測では `copy_pass` は 89.057 → 9.924 ms、最適化全体は 92.770 → 14.085 ms。各フェーズは内側の呼び出しを含む。同じ入力でも内部タイマーの有無で旧 worker の結果に差があるため、ロード全体の比較は `none` worker 同士で行った。

## ブロック・root の上書き・CALL と広い register frame

Spinel の中央値（最小–最大）。`propagate` は各15回、ロードと RSS は内部タイマーなしで各30回。

| 入力 | `propagate`（ms） | ロード（ms） | ピーク RSS（MiB） |
|---|---:|---:|---:|
| `i32-many-blocks` | 8.336 (8.257–9.199) → 0.755 (0.633–0.830) | 20.169 (19.052–21.453) → 15.372 (14.305–17.272) | 45.53 (45.53–45.55) → 33.34 (33.34–33.36) |
| `i32-root-overwrites` | 40.506 (40.123–41.007) → 1.363 (1.326–1.548) | 40.628 (39.913–68.266) → 16.417 (15.677–27.867) | 53.53 (53.50–53.55) → 51.33 (51.31–51.34) |
| `i32-copy-chain` | 5.404 (5.253–5.570) → 0.317 (0.306–0.339) | 5.407 (5.292–6.470) → 2.324 (2.256–2.628) | 11.47 (11.47–11.47) → 10.92 (10.92–10.92) |
| `i32-wide-call` | 0.462 (0.441–0.490) → 0.238 (0.225–0.271) | 4.062 (3.853–4.548) → 3.769 (3.646–4.203) | 12.22 (12.20–12.22) → 12.09 (12.08–12.09) |
| `i32-wide-frame` | 0.114 (0.111–0.129) → 0.069 (0.060–0.081) | 1.987 (1.852–2.118) → 1.932 (1.848–2.076) | 11.77 (11.75–11.77) → 12.34 (12.33–12.34) |

32,770 register・3命令の `i32-wide-frame` では4本の alias 配列を確保するため、ピーク RSS が Spinel で約0.58 MiB、CRuby で約0.42 MiB 増えた。CRuby は各10回で、ロードは 10.034 → 7.001 ms、RSS は 28.13 → 28.55 MiB。`i32-many-blocks` では leader ごとの再確保がなくなり、Spinel のピーク RSS が約12.2 MiB 減った。

小入力と対象外の i64・float・memory・EH のロード中央値には、5%を超える退行がなかった。各30回の範囲は生データに記録した。Spinel のゲスト実行は100万反復を各15回測り、`inline_mix` は 21.789 → 21.721 ms、`call_mix` は 21.619 → 21.636 ms。両方で全試行のチェックサムが一致した。

## alias 操作数

別の CRuby プロセスで `propagate` 内の alias 操作を数えた。旧方式は走査・リセットに入るたびに配列長を加算し、新方式はメソッド呼び出しと生成された配列を数えた。`bind` は self COPY を含む呼び出し数。

| 入力 | `resolve` | `write` | `bind` | leader | destination 走査セル数 変更前 → 変更後 | leader 再初期化セル数 変更前 → 変更後 | 配列確保数 変更前 → 変更後 |
|---|---:|---:|---:|---:|---:|---:|---:|
| `i32-chain-4096` | 8,194 | 4,097 | 1 | 1 | 16,793,603 → 0 | 4,099 → 0 | 2 → 4 |
| `i32-chain-8192` | 16,386 | 8,193 | 1 | 1 | 67,141,635 → 0 | 8,195 → 0 | 2 → 4 |
| `i32-many-blocks` | 4,098 | 2,049 | 1 | 2,049 | 4,202,499 → 0 | 4,202,499 → 0 | 2,050 → 4 |
| `i32-copy-chain` | 2,050 | 2,049 | 2,049 | 1 | 4,200,450 → 0 | 2,050 → 0 | 2 → 4 |
| `i32-wide-call` | 8,513 | 544 | 257 | 2 | 135,364 → 0 | 324 → 0 | 4 → 8 |

新方式の配列は `propagate` 1回につき4本で、初期化したセル数は N=4,096 で16,396、N=8,192 で32,780 だった。各 read、write、block 切り替えと bind の回数は前後一致した。このアルゴリズムで線形になるのは alias 管理で、`remove_overwritten_copies` の block ごとの `live.fill` と `remove_dead_copies` の反復は残る。

CRuby の割り当て診断で、`i32-chain-8192` の `propagate` が確保した Ruby オブジェクトは 49,193 → 32,811、`i32-many-blocks` は 26,665 → 14,379。Ruby 3.4.2 Wasm の CRuby ピーク RSS は各5回で 1,448.14 → 1,447.17 MiB（中央値）。Spinel CLI の生成 C では4本とも `sp_IntArray` になった。

## 同値性と検証

- 旧 `propagate` をテスト用参照実装として残した。seed `20261115` で100万遷移の全 register の解決先を照合し、生成した1,000関数で全 operand、分岐先、register 検証、および3組の引数による実行結果が一致した。インライン化直後の caller、手組み MIR の負の配列添字と不正入力の診断も比較した。
- 前後の24入力でデコード結果、semantic MIR、最適化結果、flat code と side table の正規化ハッシュが一致した。22入力は既定・`:all`・各機能の個別無効化と profiling 有無の16通り、Ruby Wasm の2入力は既定設定で確認した。不正 Wasm 5入力では全16設定で例外クラス、原因、Wasm PC を照合した。
- 人工 i32 の11入力で Spinel の MIR2 がバイト単位で一致した。旧キャッシュを変更後のバイナリで読み込み、各入力の3組の引数で Wasmtime と結果を照合した。MIR2 のバージョンは据え置いた。
- `bundle exec rake test` は317件・33,099 assertions。native 専用の85件は `make spinel-test RUBY="bundle exec ruby"` で全件実行し、2,714 assertions が通過した。`bundle exec rake check` の型検査と `bundle exec rake parity` の CRuby・Spinel 各436 fixture も通過した。
- `scripts/verify_ruby_wasm.rb` では Ruby 4.0.9 の `-e`、`require_relative`、`exit 7` の出力と終了コードが Wasmtime と一致した。CRuby・Spinel 双方で MIR2 の miss / hit と snapshot の保存・復元を確認した。

read operand の書き換えではコピー直後の Integer 配列を使う。Spinel の CLI ビルドではこの形で `OptionParser` の添字代入と型推定が干渉するのを避けられた。

## 再現

同じ Wasm を両リビジョンで使用する。基準の checkout は `1bce886`。変更後の checkout で `benchmark/generate_mir_generation_fixtures.rb` を実行すると `i32-chain` と追加の人工関数が得られる。Ruby 3.4.2 と 4.0.9 の入手元とハッシュは ADR 0014 の計測記録にある。 [Ruby Wasm の入力](efflorescence-mir-build-validation-and-decoding-results.md)

各 checkout で別の出力ディレクトリに worker を作る。ロード全体は `none`、内訳は `detail`。CRuby は比較時に `RUNTIME=cruby` を指定する。

```sh
ruby benchmark/generate_mir_generation_fixtures.rb "$fixtures"
ruby benchmark/prepare_mir_generation_profile.rb "$build_dir" "$mode"
spinel -I "$build_dir/lib" --strict-require -O2 "$build_dir/mir_generation_worker.rb" -o "$build_dir/worker"
RSS=1 RUNS=15 ruby benchmark/compare_mir_generation_builds.rb \
  before="$before_dir" after="$after_dir" -- "$fixtures"/i32-chain-*.wasm
```

`benchmark/profile_copy_propagation.rb` と `benchmark/profile_mir_generation_allocations.rb` は CRuby で各 checkout の `lib` を `-I` に指定して実行する。CLI 計測は各 checkout で `make spinel` し、`WARDITE_TRACE=1` で `load_from_buffer` を記録する。ゲスト実行は `benchmark/optimization_worker.rb` を各 checkout の `lib` で Spinel ビルドし、`i32_mix.wasm inline_mix 1000000 123` と `i32_mix.wasm call_mix 1000000 123` を渡す。いずれも時間を測る際は MIR2 キャッシュを無効にし、前後を交互に起動する。

正規化比較は `ruby -I "$source/lib" test/support/mir_generation_digest.rb "$wasm" matrix` を前後で実行し、出力を照合する。MIR2 の確認では各バイナリを別々の空キャッシュに対して `--new-engine --no-wasi --mir-cache "$cache" --invoke run -- "$wasm" 123` で実行する。生成された `.mir2` を `cmp` で照合し、変更後のバイナリで変更前のキャッシュを指定してヒットと実行結果を確認する。
