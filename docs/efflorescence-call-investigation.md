# Efflorescence VM: Spinelの内部callコスト調査

2026-11-04、`86c6e83` のVMを対象に調査した。結論は、**フレームのallocationだけでなく、再利用時の全レジスタ初期化が大きなコストになっている**、というものだった。今回の `call_mix` では、この初期化を省く限定的な実験で実行時間が約21%減った。

VM本体は変更していない。実験用の変更は `build/benchmark/call-cost/` にコピーしたライブラリに適用する。

以下は改修前の調査記録。現在のVMには[初期化範囲を絞る改修](efflorescence-register-initialization.md)を適用した。
再実行スクリプトは、全初期化を再現する `full_reset` と現在の `locals_only` を含む5構成へ更新している。

## 測定条件

- macOS 27.0.1、Apple Silicon、CRuby 4.0.9、Spinel `2026.10.25+1967 (6e7fc1355)`。
- Spinelは `-O2`、整数overflowチェックは通常の設定。時間測定にはデバッグ・allocation・MIR計測機能を有効にしない。
- 1,000,000 rounds、seed 123。各構成は2回ウォームアップ後に7回測定。表は平均 ± 標本標準偏差。
- 1サンプルにつき1プロセス。ロード、MIR変換、実行、プロセス全体を別々に記録。主要な比較対象は `call_unboxed` の実行時間。
- 全24構成をラウンドロビンで実行し、順序を回転・反転する。各測定結果のchecksumを検証する。
- 時間計測とは別のプロセスでMIR命令数・フレーム数とSpinelのallocationを取得する。

以前提示された13.4 / 25.8 msとは回数・エントリポイント・測定時点が異なるため、絶対時間を直接比較しない。

## 実験A: 段階的に処理を増やす

元の `benchmark/i32_mix.wat` 全体を使い、同じループに以下の対照を追加した。

| export | 処理 | 実行時間 (ms) | 動的MIR命令数 |
| --- | --- | ---: | ---: |
| `empty_loop` | roundsを減らし、seedを返す | 24.280 ± 0.454 | 3,000,003 |
| `call_identity` | `local.get 0` だけの関数を呼ぶ | 82.670 ± 1.228 | 5,000,003 |
| `inline_add_one` | ループ内で1を加算 | 32.376 ± 0.580 | 4,000,003 |
| `call_add_one` | 1を加算する関数を呼ぶ | 96.744 ± 1.974 | 6,000,003 |
| `inline_mix` | 元のinline_mix | 64.264 ± 0.842 | 7,000,003 |
| `call_mix` | 元のcall_mix | 147.803 ± 0.945 | 9,000,003 |

ここでは現在のフレーム再利用を有効にしている。3つのcalleeはいずれも引数1個、戻り値1個、非引数ローカル0個。

`call_identity - empty_loop` は58.390 ms、`call_add_one - inline_add_one` は64.367 ms、`call_mix - inline_mix` は83.539 msだった。100万回なので数値上はそれぞれ58.390 / 64.367 / 83.539 ns/回になる。

ただし、いずれの差にも1回につき `CALL` とcalleeの `RETURN` の2ディスパッチ、引数・戻り値の移動、フレーム切り替え、初期化が含まれる。単独の「関数呼び出し命令のコスト」とは解釈できない。元のmix処理は同じでも、インライン化で生じるレジスタ配置の違いもある。

## 実験B: allocationと初期化を分ける

現在のVMはすでに、呼び出しごとのpoolでFrameとレジスタ配列を再利用する。そこで次の4構成を比較した。

| 構成 | Frame | レジスタ配列 | 再利用時の初期化 |
| --- | --- | --- | --- |
| `fresh` | 毎回生成 | 毎回生成 | 全スロット |
| `registers_only` | 毎回生成 | 再利用 | 全スロット |
| `pooled`（現在） | 再利用 | 再利用 | 全スロット |
| `metadata_only`（実験） | 再利用 | 再利用 | 戻り先・PCだけ |

`fresh` は既存の `frames` 最適化を無効にする。`registers_only` は返却済みFrameの配列を新しいFrameへ渡す。`metadata_only` は再利用時の `Frame#reset` を置き換える。初回生成時には通常どおり定数を含む全スロットを初期化し、各呼び出しの引数は通常のCALL処理で上書きする。

| export | fresh (ms) | registers_only (ms) | pooled (ms) | metadata_only (ms) |
| --- | ---: | ---: | ---: | ---: |
| `call_identity` | 100.928 ± 1.569 | 87.463 ± 1.106 | 82.670 ± 1.228 | 72.689 ± 2.045 |
| `call_add_one` | 114.795 ± 8.827 | 101.205 ± 2.575 | 96.744 ± 1.974 | 80.585 ± 1.528 |
| `call_mix` | 166.752 ± 2.236 | 151.328 ± 0.993 | 147.803 ± 0.945 | 117.189 ± 0.958 |

`call_mix` では、全初期化を省くと30.613 ms、20.7%減った。プロセス全体でも152.023 → 121.416 msだった。`inline_mix` は各構成で63.911〜64.322 msであり、callee再利用がない対照として大きな変化はなかった。

calleeのレジスタ数はidentityが2、add_oneが4、mixが12。最適化後もレジスタ番号は詰め直していない。mixの実際の命令は以下の5個だが、毎回12スロットを初期化している。

```text
I32_XOR_SHR_U_IMM r4, r0, 13
I32_MUL_IMM       r6, r4, 1664525
I32_ADD_IMM       r0, r6, 1013904223
I32_XOR_SHL_IMM   r1, r0, 7
RETURN           r1
```

**`metadata_only` はこのfixture専用の仮説検証であり、汎用の最適化として導入していない。** 非引数ローカルがあるFrameの再利用は明示的に拒否する。任意の制御フロー・再帰・再入を対象とした正しさの検証は今回の実験範囲に含めない。

## Time Profilerと生成C

[Spinelの公式手順](https://github.com/matz/spinel/blob/master/docs/profiling.md) に従い、`--profile` 相当の `-O2 -g -fno-omit-frame-pointer` で生成Cをコンパイルした。`--no-line-map` を指定し、Rubyではなく生成Cの行番号を残した。

ヘッダー、StringIOのリンクオブジェクト、`libspinel_rt.a`、必須define・Cフラグは、インストール済みSpinelの `--print-build` から取得する。生成Cを永続的な `worker.o` にコンパイルしてからリンクし、macOSでは `dsymutil` でDWARFを保存する。コンパイル・リンクコマンドもJSONに記録する。

現在のVMの `call_mix(50_000_000, 123)` をInstruments Time Profilerで記録した。実行は7.513秒、checksumは `3380275835` で独立したRuby参照計算とも一致した。解析対象は7,495個のCPUスタックサンプルだった。

| 関数 | Self | Inclusive |
| --- | ---: | ---: |
| `sp_VM_execute_flat` | 43.63% | 99.36% |
| `Frame#reset` | 2.28% | **23.82%** |
| `FramePool#acquire` | 1.45% | 25.20% |
| `sp_IntArray_length` | 11.13% | 11.13% |
| `_sp_gc_root_push` | 9.71% | 9.71% |
| `sp_IntArray_set` | 6.94% | 6.94% |

Inclusiveは子の時間を含み、行どうしが重なる。resetの約24%という観測は、初期化を省いた差分実験の約21%という改善と整合する。ただし、サンプリング結果から厳密な改善率を予測するものではない。

`_sp_gc_root_push` はGCが追跡する参照の登録処理であり、ヒープallocationやGC回収時間そのものではない。この記録では `sp_gc_collect` のサンプルは観測しなかった。

生成CとdSYMで `Frame#reset` の `worker.c:15272` / `:15276` への対応を確認した。一方、最適化後の `execute_flat` 内のサンプルは同一のC行に集約されていたため、そこから命令別のCPU割合は推定しない。

生成Cでは以下も確認できた。

- 命令列とレジスタは `sp_IntArray *`、opcode分岐はCのswitch。
- `frames`、`pools`、`calls` は `sp_PolyArray *`。取り出したFrameやCallSiteの参照にタグ・クラスの判定が残る。
- RETURNには `pc`、`return_register`、`release` への多相ディスパッチが残る。整数値のunboxingだけでは、これらの参照処理は消えない。
- 全レジスタ初期化では、長さの確認、初期値の読み出し、配列への書き込み、GC rootの登録などが反復される。

これらは次の改善候補を示す静的な証拠であり、各処理の削減効果を個別に測定したものではない。

## Allocation

Spinelの `SPINEL_ALLOC_REPORT` を時間測定とは別に実行した。同一バイナリの0回と10,000回を比較する。

| 構成 | Frame総数: 0回 → 10,000回 | `(no-scan)` の増加数 |
| --- | ---: | ---: |
| fresh | 1 → 10,001 | 10,000 |
| registers_only | 1 → 10,001 | 1 |
| pooled | 1 → 2 | 1 |
| metadata_only | 1 → 2 | 1 |

これは `call_mix` の値。`(no-scan)` は整数配列などを含む集合で、レジスタ配列だけを数える専用カウンタではない。現在の再利用により、allocationはすでに呼び出し回数に比例しなくなっている。

## 正しさと次の改善候補

全6export、4つのSpinel実験版で `(0,0)`、`(0,123)`、`(1,0xffffffff)`、`(10,123)`、`(1000,0xffffffff)` を検証した。旧VM・独立した参照計算と一致した。100万回の測定・カウンタ取得でも全checksumを検証した。

100万回・seed 123のchecksumはempty/identityが123、add_oneが1000123、mixが1259766978。既存の最適化テストも10 tests / 3,000 assertions、失敗・エラー0だった。

次に進めるなら、以下の順がよさそうだ。

1. **初期化範囲を定義する。** 引数はCALLで代入し、非引数ローカルは0に戻し、定数は保持する。一時レジスタは定義前に読まれないことを検証してから初期化を省く。分岐・再帰・再入・trap後も検証する。
2. **不要なスロットを削除する。** 定数即値化・COPY削減後にレジスタを詰め直し、配列サイズと初期化対象を減らす。
3. **Frame / CallSite / poolの型を具体化する。** `fetch` などの利用形やアクセサの境界を見直し、Spinelが型を保てるようにする。生成Cから多相ディスパッチが減ったことと実測の両方を確認する。

## 再実行

```sh
# 現在のスクリプトは5戦略 × 6exportの30構成を比較する
RUNS=7 WARMUPS=2 ruby benchmark/investigate_calls.rb 1000000 123

# 生成C、ランタイム設定、-O2 -gバイナリ、dSYM
ruby benchmark/build_call_profile.rb

xcrun xctrace record --template 'Time Profiler' --no-prompt \
  --time-limit 15s --output build/benchmark/call-cost/profile/call-mix.trace \
  --launch -- "$PWD/build/benchmark/call-cost/profile/worker" \
  "$PWD/build/benchmark/call-cost/call_cost.wasm" call_mix 50000000 123 inline

xcrun xctrace export \
  --input build/benchmark/call-cost/profile/call-mix.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  --output build/benchmark/call-cost/profile/time-profile.xml

python3 benchmark/summarize_call_profile.py \
  build/benchmark/call-cost/profile/time-profile.xml
```

同名のtraceが存在する場合は別の出力名を使う。通常のベンチマークにはRuby、Spinel/Cツールチェーン、wasm-toolsが必要。プロファイルには加えてmacOSのXcode Instrumentsを使う。

今回の[全サンプルと集計結果](../benchmark/results/call_cost_spinel_2026-11-04.json)を保存した。生成WAT・実験用ライブラリ・ネイティブバイナリ・C・DWARF・traceはサイズが大きいため、再生成可能な `build/` 以下に置く。
