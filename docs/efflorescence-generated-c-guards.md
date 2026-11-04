# Efflorescence VM: Spinelの生成Cに残る保護処理

2026-11-04、`999fde3` のflat実行器を調査した。改善余地は大きかった。
`loop do` を `while true` に変えたコピーでは、Spinelの `call_mix` 実行時間が
278.609 → 176.714 ms、**36.6%短縮**した。
さらに、命令フェッチに重複して生成される一時GCルートだけを生成Cから除く実験では
103.755 ms、**62.8%短縮**した。

以下は調査時点の測定結果である。その時点では製品VMとインストール済みSpinelを変更していなかった。
現在はflat実行器の `while true` 化を製品ソースへ反映し、パッチなし・ありのSpinelで検証と計測を完了した。
段階的な検証の結果は末尾の「Warditeへのwhile採用と最終比較」に記録する。

## 命令フェッチに生成される処理

Rubyの `instructions.fetch(pc)` は、おおむね次のCになる。変数名は読みやすく省略した。

```c
sp_IntArray *receiver = lv_instructions;
SP_GC_ROOT(receiver);
sp_int index = lv_pc;
sp_int length = sp_IntArray_length(receiver);
sp_int normalized = index < 0 ? index + length : index;
/* 範囲内なら読み、範囲外ならIndexError */
```

`_sp_gc_root_push` は、この一時変数のアドレスをGCルートのスタックへ登録する。
GCの回収処理そのものではない。式を抜けるとcleanupで登録を解除する。
[Spinelの実装](https://github.com/matz/spinel/blob/6e7fc13556709bf7d7ba4af5bd1d12bebc00733e/lib/sp_gc.h#L119)を確認した。

一方、`lv_instructions` 自体は関数冒頭ですでに `SP_GC_ENTRY_PTR(lv_instructions)` により
ルートフレームへ登録されている。今回のPC式の評価中には、このローカル変数は書き換わらない。
この条件なら、同じ配列を指す一時変数の追加登録を省ける可能性がある。

flat実行器にはこのフェッチが静的に38箇所ある。インライン化ありのmixでは
`25 * rounds + 8`、なしのcallでは `31 * rounds + 8` ワードを取得する。
500万回では、それぞれ125,000,008回、155,000,008回の一時登録に相当する。
これは既存のフェッチ位置テストから求めた回数で、時間測定にはカウンタを入れていない。

Spinelの[型付き配列fetchのコード生成](https://github.com/matz/spinel/blob/6e7fc13556709bf7d7ba4af5bd1d12bebc00733e/src/codegen_call_recv.c#L2610)は、
レシーバーを常に一時ルートに登録する。コメントにあるとおり、一般には必要な処理である。
一時的に作った配列に対し、添字の計算でallocationやGCが起きても配列を生存させる必要がある。

既存の `emit_recv_rooted` には一部の重複登録を避ける仕組みがあるが、fetchの生成箇所はこのhelperを使わない。
`push_recv_in_slot` には引数評価がレシーバーの保存先を壊さないことを調べる仕組みがある。
これらは上流側の改善を考える際の参考になるが、そのままで今回の全PC式を扱えることは確認していない。

## `loop do` のコストも大きい

今回の `execute_flat` は、`Kernel#loop` が `StopIteration` を捕捉するための例外フレーム付きで生成される。
そのCには、関数内の `setjmp` 1箇所、`volatile` を含む宣言17行、
反復冒頭でのブロックローカル13変数の再初期化があった。

コピーしたVMの `execute_flat` だけを `while true` に変えると、これらが0になった。
命令フェッチの38箇所の一時ルート、境界チェック、整数overflowチェック、関数のルートフレームは残る。
生成されたwhileにはsignalのpollもある。

`setjmp` 自体を毎命令実行するわけではない。
例外処理に伴う変数の保持や毎反復の初期化など、生成コード全体への影響がある。
個々の要因の寄与率までは分離していない。

参照: [Kernel#loopのコード生成](https://github.com/matz/spinel/blob/6e7fc13556709bf7d7ba4af5bd1d12bebc00733e/src/codegen_call_kernel.c#L1142)、
[StopIterationの可能性の解析](https://github.com/matz/spinel/blob/6e7fc13556709bf7d7ba4af5bd1d12bebc00733e/src/analyze_util.c#L5466)。

### Rubyとしての意味の差

`loop do` は `StopIteration` を捕捉してその結果を返すが、`while true` は呼び出し元へ伝播させる。
現在の対応するWasm命令にはRubyのiteratorやhost callbackがなく、この違いが必要になる箇所は見つからなかった。
将来host functionなどを追加するときは、例外の伝播方針を明示する必要がある。

whileではブロックローカルの毎反復のリセットもなくなる。
今回の正常な制御フローでは各変数は使用前に代入され、再帰・trap後の再実行も通った。
ただし、最後に使ったFrame等への一時参照が、loop版より長く残る可能性はある。

## 比較結果

macOS arm64、CRuby 4.0.9、Spinel `2026.10.25+1967 (6e7fc1355)`、Apple clang 21.0.0。
生成CをSpinelの `--print-build` にある設定でリンクし、全構成を **`-O2` 固定**でコンパイルした。
通常のGCと整数overflowチェックを有効にしている。

元の `i32_mix.wat` 全体、5,000,000 rounds、seed 123、ウォームアップ2回後に7サンプル。
順序を入れ替えて測定した。単位ms、平均 ± 標本標準偏差。以下はworker内部の実行時間。

| 構成 | inline_mix | call_mix（通常） | call_mix（インライン化なし） |
| --- | ---: | ---: | ---: |
| 現状 | 279.549 ± 3.997 | 278.609 ± 4.379 | 444.151 ± 9.325 |
| whileのみ | 178.978 ± 7.566 | 176.714 ± 1.499 | 267.337 ± 2.822 |
| 重複ルート除去のみ | 202.172 ± 1.188 | 200.919 ± 4.888 | 370.623 ± 3.745 |
| while + 重複ルート除去 | 103.743 ± 0.551 | 103.755 ± 0.910 | 213.878 ± 9.868 |

通常の `call_mix` は小関数インライン化が有効なため、実際のCALL/RETURNは残らない。
インライン化なしでも、whileで39.8%、組み合わせで51.8%短縮した。
各変更の効果は加算できない。ルートの登録だけでなく、Cコンパイラの最適化への影響もありうるが、
どの機械語最適化が差を生んだかまでは特定していない。

同じ入力のCLI全体も別に測定した。

| 構成 | inline_mix | call_mix（通常） | call_mix（インライン化なし） |
| --- | ---: | ---: | ---: |
| 現状 | 283.950 ± 2.928 | 284.554 ± 1.595 | 443.090 ± 2.149 |
| whileのみ | 182.744 ± 2.566 | 182.365 ± 0.707 | 277.854 ± 18.653 |
| 重複ルート除去のみ | 206.262 ± 0.660 | 206.974 ± 8.114 | 381.185 ± 2.629 |
| while + 重複ルート除去 | 108.642 ± 0.661 | 108.872 ± 1.606 | 214.556 ± 1.705 |

CLIとworkerは別エントリポイントで型推論も異なる。両者の差をロード・起動時間とは解釈しない。
全サンプルが独立したRuby参照計算のchecksum `1647235310` と一致し、
別実行のMIRカウンタも各構成で一致した。
元の受け入れ8入力も、inline/call、インライン化なしのcallで検証した。

[全サンプル、生成Cの静的集計、ソース・バイナリのSHA256、ビルドコマンド](../benchmark/results/generated_guards_spinel_2026-11-04.json)。
短い通常ベンチマークや他のWasm、他のSpinelバージョンでの改善率は未確認。

### `[] || raise` は逆効果だった

`fetch` を `(instructions[pc] || raise(IndexError, ...))` に置き換える実験も行った。
境界外で例外を出し、0も正しく読めるが、生成CではPC・opcode等8変数が `sp_RbVal` になった。
整数配列自体は `sp_IntArray` のままでも、スカラーのboxingと汎用演算が増えた。

100万回・ウォームアップ1回後3サンプルの探索的な比較では、通常のcallが
54.854 → 116.080 ms、whileと組み合わせても93.040 msだった。
ルート登録の削減だけを見て採用するべきではない。
[探索的測定の全サンプルとソース](../benchmark/results/generated_guards_exploratory_2026-11-04.json)を保存した。

## Instrumentsでの確認

同じ3構成を `-O2 -g -fno-omit-frame-pointer` とdSYM付きでビルドし、
Time Profilerで各1回、通常のcallを50,000,000 rounds、seed 123で実行した。
checksumは独立した参照計算の `3380275835` と一致した。

| selfのサンプル時間 | 現状 | whileのみ | while + 重複ルート除去 |
| --- | ---: | ---: | ---: |
| サンプルCPU時間の合計 | 2,766 ms | 1,779 ms | 1,046 ms |
| execute_flat本体 | 1,729 ms (62.5%) | 792 ms (44.5%) | 611 ms (58.4%) |
| `_sp_gc_root_push` | 385 ms (13.9%) | 126 ms (7.1%) | 検出なし |
| `sp_IntArray_length` | 207 ms (7.5%) | 190 ms (10.7%) | 37 ms (3.5%) |
| `sp_int_add_overflow_p` | 21 ms (0.8%) | 220 ms (12.4%) | 144 ms (13.8%) |

インライン関数を含むサンプルの帰属であり、各処理の厳密な所要時間ではない。
「検出なし」は処理が全く存在しないという意味ではない。
全構成で関数のルートフレームは保持され、重複除去後も一時ルートは静的に2箇所残る。
割合が増えた項目もあるため、割合だけでなく絶対サンプル時間を併記した。
性能比較の主データは、上記のプロファイラなし・7サンプルの測定である。

[プロファイル集計、チェックサム、コマンドとバイナリSHA256](../benchmark/results/generated_guards_profile_2026-11-04.json)。
ローカルのtraceは `build/benchmark/generated-guards/profile/<構成>/time-profile.trace` にある。

## 重複ルート除去の範囲と検証

生成Cの実験では、次の形だけを対象にした。

- 対象は `execute_flat` 内の `sp_IntArray *temporary = lv_instructions`。
- `lv_instructions` が関数のルートフレームに登録されていることを確認する。
- 添字はローカルPC、またはPCへの1・2・3の組み込み整数加算に限る。
- 認識した箇所が38箇所すべてと一致しなければ中止する。
- `fetch` の負添字・境界検査・例外、整数overflowチェック、他のルート登録を残す。

任意のfetchからルート登録を消せるわけではない。例えば次の式では、
引数評価中に元の配列を指すローカル変数が上書きされるため、一時レシーバーの保護が必要になる。

```ruby
ary.fetch(begin
  ary = []
  GC.start
  0
end)
```

Spinelへの一般的な変更には、レシーバーの生存期間と引数評価の副作用の解析が必要になる。
上流の `test/array_fetch_recv_root.rb` にある、一時配列とallocationを伴う添字の回帰テストも守る必要がある。
今回の生成Cの置換は、その一般的なコンパイラ修正の代用にはならない。

while、重複ルート除去、組み合わせのコピーで、各 **116 tests / 10,888 assertions、失敗・エラー・省略0**。
コピー側のGemfileでBundlerを分離した。
生成Cの型検証テストは、C引数名 `lv_frame__in` に加えて `lv_frame` も認めるよう、コピー側の正規表現だけ調整した。
Frame/poolの具体型の検査は残している。元のテストと製品ソースは変更していない。

さらに、対照を含む4構成のネイティブ実行ファイルで
`SPINEL_GC_STRESS=1 SPINEL_GC_VERIFY=1 SPINEL_GC_STATS=1` を使用した。
各構成で **23,564回のGC** が実際に実行され、再帰、相互再帰、0・複数引数、
ローカル初期化、ローカル値のスナップショット、void、多値、trap後の同一VM再実行が成功した。
インライン化とフレーム再利用を無効にし、呼び出し中のallocationを増やした。
STRESSは閾値を下げる設定であり、毎allocationでの強制GCという意味ではない。

ホスト側から不正PCを持つMIRへ差し替える検証は、Rubyでは対照・whileの両方で成功した。
ただし、その操作をネイティブ用harnessに含めるとSpinelの命令配列の型が汎用値へ広がったため、
そのままでは同じ型付き実行器の検証にならなかった。
ネイティブのGC検証ではこの操作を除き、型付き命令配列とルート登録の生成を再確認した。
不正PCの動的検証範囲と、生成Cの境界検査が残ることの確認を区別している。

[検証結果、harness全文、WATとビルドコマンド](../benchmark/results/generated_guards_validation_2026-11-04.json)。
この検証は調査対象での根拠であり、任意のRubyプログラムに対するルート除去の証明ではない。

## 再実行

Ruby、Spinel/C toolchain、`wasm-tools` が必要。現状ソースを `build/` 以下へコピーして比較する。
生成Cの形が変わった場合は、認識チェックで中止する。

```sh
VARIANTS=baseline,while_loop,c_root_elision,while_c_root_elision \
  CLI=1 RUNS=7 WARMUPS=2 \
  GUARDS_DIR=build/benchmark/generated-guards/final \
  ruby benchmark/investigate_generated_guards.rb 5000000 123
```

結果は `build/benchmark/generated-guards/final/results.json`。
`VARIANTS` を省略すると、遅かった `[] || raise` の2構成も含める。
`SPINEL` と `CC` は指定可能。最適化レベルは実験のため `-O2` に固定している。

GC検証も再実行する場合は、上の4構成をビルドした後、記録からharnessを取り出す。

```sh
python3 - <<'PY'
import json, subprocess
from pathlib import Path
data = json.loads(Path('benchmark/results/generated_guards_validation_2026-11-04.json').read_text())
directory = Path('build/benchmark/generated-guards/validation')
directory.mkdir(parents=True, exist_ok=True)
(directory / 'driver.rb').write_text(data['driver_source'])
(directory / 'run.py').write_text(data['runner_source'])
for name, fixture in data['fixtures'].items():
    wat = directory / (name + '.wat')
    wat.write_text(fixture['source'])
    subprocess.run(['wasm-tools', 'parse', str(wat), '-o', str(wat.with_suffix('.wasm'))], check=True)
PY
python3 build/benchmark/generated-guards/validation/run.py
```

Instruments用ビルドと記録例:

```sh
PROFILE=1 VARIANTS=baseline,while_loop,while_c_root_elision \
  RUNS=2 WARMUPS=0 GUARDS_DIR=build/benchmark/generated-guards/profile \
  ruby benchmark/investigate_generated_guards.rb 10 123

directory="$PWD/build/benchmark/generated-guards/profile/while_loop"
xcrun xctrace record --template 'Time Profiler' --no-prompt \
  --time-limit 10s --output "$directory/time-profile.trace" \
  --target-stdout "$directory/time-profile.stdout" \
  --launch -- "$directory/worker" \
  "$PWD/build/benchmark/generated-guards/profile/i32_mix.wasm" call_mix 50000000 123
open "$directory/time-profile.trace"
```

ビルド時の10回入力はスモーク確認用で、性能測定には使わない。traceの出力先は既存ファイルを避ける。

## 次の改修候補

まずは `while true` 化を独立した変更として検討できる。
Pure Rubyで境界検査を維持でき、今回の実際のCALLを通る測定でも差があった。
採用時はStopIterationの伝播方針を明記し、CRuby/YJITと短い通常CLIの測定も追加する。

重複ルートの削減は、Spinel側で安全条件を解析して生成を省く方向が適している。
今回の限定的な生成Cの置換を通常ビルドへ持ち込まず、上流のGC回帰テストを含む修正として検討する。
境界検査・overflow検査の除去や、GC全体の無効化は今回の実験には含めていない。

## 追記: Spinel側の試作パッチ

同日、`/Users/udzura/ghq/github.com/matz/spinel` の `6e7fc1355` から
`codex/fetch-root-elision` ブランチを作成し、コンパイラ側に試作を実装した。
パッチと回帰テストはローカルコミット `6f1a2c259` に保存した。
インストール済みのコンパイラは置き換えず、チェックアウトの `bin/spinel` をビルドして使用した。

`src/codegen_call_recv.c` に `fetch_recv_in_slot` を追加した。
対象は引数1つ・ブロックなしの型付きArray#fetchに限り、次を確認する。

- レシーバーが、通常のCローカルとして出力される配列のローカル変数である。
- closureのcellや捕捉スロットではなく、コード生成時の別の一時変数への置換もない。
- 添字がunboxed整数のローカル、整数リテラル、または整数ローカルへの整数リテラルの加算である。
- 加算の場合、既存の `cplan_user` がユーザーメソッドへの呼び出しなしと判定する。

条件を満たす場合だけ、一時レシーバーの `SP_GC_ROOT` の生成を省く。
関数のルート登録、fetchの境界検査、整数overflowチェックは変更しない。
default・block付き、任意のメソッド呼び出しを含む添字、配列変数の代入、
一時レシーバー、Integer#+の再定義は従来の経路を使う。
既存の最適化判断レジストリに `fetch-slot` を追加し、判断の記録と個別無効化にも対応した。

最初は `subtree_is_plain_value` を使ったが、プログラム全体にある動的呼び出しも保守的に扱うため、
Warditeでは `pc + 定数` の37箇所が対象外になった。
最終版は構文を整数ローカルと定数の加算に絞ったうえで、実際の呼び出し先を既存のCallPlanで確認する。
これにより、Warditeの命令フェッチ38箇所すべてで追加ルートがなくなった。

### パッチ前後の比較

パッチ前に同じチェックアウトのコンパイラを `bin/spinel-fetch-root-baseline` へ保存し、
両コンパイラからそれぞれworkerとCLIを生成した。生成Cの手編集はしていない。
Rubyソースは元のloop版と、コピーしたwhile版をそれぞれ比較した。
ネイティブは `-O2` 固定、500万回、seed 123、ウォームアップ2回後に7回測定。
順序を入れ替え、すべてのchecksumと、別実行のMIRカウンタが一致することを確認した。

単位ms、worker内部の実行時間の平均 ± 標本標準偏差。

| Rubyソース | コンパイラ | call_mix（通常） | call_mix（インライン化なし） |
| --- | --- | ---: | ---: |
| loop | パッチ前 | 397.733 ± 0.717 | 631.705 ± 6.346 |
| loop | パッチ後 | 286.970 ± 1.455 | 540.146 ± 10.327 |
| while | パッチ前 | 253.095 ± 0.403 | 378.801 ± 2.758 |
| while | パッチ後 | 151.241 ± 8.857 | 302.834 ± 5.981 |

コンパイラのパッチだけでは、現状のloop版で27.8%短縮、実際のCALLを残した場合も14.5%短縮した。
while版ではそれぞれ40.2%、20.1%短縮した。
前段の生成Cを直接編集した実験とは別の測定であり、絶対時間をまたいで比較しない。

10万回の短い入力も測定した。通常callのCLI全体は、loop版で
15.345 ± 3.319 → 11.737 ± 0.503 ms、while版で
11.179 ± 0.388 → 8.612 ± 0.468 msだった。
短いサンプルには外れ値もあるため、一般的な改善率は長い入力と区別する。

### 検証と利用方法

- fetch関連とpushのGC回帰テスト **43ファイル**を、通常・GCストレスの両方で実行し、すべて成功。
- `make decisions-test` 成功。`fetch-slot` を含む判断の記録・再現・無効化を検証。
- 正常なローカル/加算/literalのfetchで追加ルート0、Integer#+の再定義では追加ルート1を生成Cで確認。
- パッチ済みコンパイラでビルドしたCLIを指定し、Warditeの **116 tests / 10,888 assertions、失敗・エラー・省略0**。
- loop/whileのネイティブ検証用実行器でも、各 **23,564回のGC** と検証機能を有効にして成功。
  命令配列が型付きで、重複ルート0・関数ルートありであることを、生成Cを編集せずに確認した。

Spinel全体のテストスイートは実行していない。
[全サンプル、変更差分、回帰テスト、GC検証、ソース・コンパイラ・バイナリのSHA256](../benchmark/results/spinel_fetch_root_patch_2026-11-04.json)を保存した。

計測の手順4以降でパッチを再び使う場合:

```sh
cd /Users/udzura/ghq/github.com/matz/spinel
git switch codex/fetch-root-elision
make -j4 bin/spinel
make decisions-test
```

Warditeの通常ベンチマークへ使う場合:

```sh
cd /Users/udzura/ghq/github.com/udzura/wardite
SPINEL=/Users/udzura/ghq/github.com/matz/spinel/bin/spinel \
  SPINELFLAGS=-O2 ruby benchmark/compare.rb
```

この指定では、現在チェックアウトしてビルドしたSpinelで製品のRubyソースを測定する。

## Warditeへのwhile採用と最終比較

ユーザーの指定した順序で、while化とSpinelのパッチを分けて検証した。

1. Spinelの元ブランチ `master`（`6e7fc1355`）へ戻し、`bin/spinel` を再ビルド。
2. Warditeの `execute_flat` を `loop do` から `while true` へ変更。
3. 一度停止し、パッチなしSpinelでユーザーが計測。
4. 結果を受け取り、Spinelを `codex/fetch-root-elision` へ戻して再ビルド。
5. パッチありSpinelの通常ベンチと、保存したパッチなしバイナリとの交互比較を実施。
6. 結果と検証をWarditeのPRへ反映。

flat実行器では命令実行中の `StopIteration` もRubyの呼び出し元へ伝播させる。
従来の `Kernel#loop` による暗黙の捕捉を外す方針を明示し、例外後に同じVMを再実行できることをテストする。
Steepはwhile式がnilを返す可能性を扱うため、ループ後に到達不能な例外を置いてIntegerの戻り値契約を保つ。
生成Cの検証も、Frameの具体型を保持しながら `setjmp` と `volatile` がないことを確認する。
命令フェッチの `Array#fetch`、境界検査、整数overflowチェックは維持する。
パッチなしSpinelでのビルド、117 tests / 10,893 assertions、型チェックが成功した。
生成Cでは追加ルート38箇所が残り、`setjmp` と `volatile` は0であることを確認した。

調査用スクリプトは、現在のwhileソースからも旧loop版をコピー内で再構築し、両方を比較できる。
Spinelの実験パッチは専用ブランチのローカルコミットに保持し、WarditeのCIは未改造の `6e7fc1355` のままとする。

### ユーザー計測とパッチありの通常ベンチ

ユーザーのパッチなし計測は、inlineが9.252 ± 0.314 ms、callが9.441 ± 0.400 msだった。
コンソール表示と一致するローカルのHyperfine出力を、上書きする前に保存した。
そのJSONはコマンド名だけを含み入力を記録していないため、入力は `compare.rb` のデフォルトとして解釈し、
入力が明示された同一セッション内の比較とは区別する。
[ユーザー計測の生データと、その時点の実行ファイルのSHA256](../benchmark/results/while_user_unpatched_2026-11-04.json)。

その後、パッチありのコンパイラを明示して `SPINELFLAGS=-O2 ruby benchmark/compare.rb` を実行した。
入力は明示的に確認したデフォルトの100,000回、seed 123456789、ウォームアップ2回後5サンプル。
全8コマンドのchecksumが独立参照と一致した後に計測する。
単位ms、CLI全体の平均 ± 標準偏差。

| ランタイム | inline_mix | call_mix |
| --- | ---: | ---: |
| Efflorescence / パッチありSpinel | 7.060 ± 0.275 | 7.039 ± 0.277 |
| iwasm | 5.306 ± 0.191 | 6.081 ± 0.245 |
| Wasmtime / Pulley | 8.611 ± 0.333 | 11.252 ± 0.748 |
| Wasmtime | 6.792 ± 0.409 | 7.132 ± 0.386 |

起動・ロードを含む、この小さなWasmの測定結果である。一般的なWasm実行性能の同等性を示すものではない。
ユーザーのパッチなし計測から時間が空いているため、その差だけをコンパイラの改善率とはしない。
[パッチありの全サンプル、入力、バージョン、コマンド出力](../benchmark/results/while_patched_external_2026-11-04.json)。

### 同じwhileソースでのコンパイラ比較

ユーザー計測時のパッチなし実行ファイルを保存し、同じRubyソースをパッチありでビルドした実行ファイルと比較した。
両方のソースSHA256が一致し、コンパイラとバイナリのSHA256も保存している。
各コマンドを順序を変えながら交互に実行し、各checksumを独立参照と照合した。
seed 123456789、ウォームアップ2回後7サンプル。以下は500万回のCLI全体、単位ms。

| 対象 | パッチなしSpinel | パッチありSpinel | 時間の短縮 |
| --- | ---: | ---: | ---: |
| inline_mix | 261.538 ± 4.829 | 162.326 ± 14.718 | 37.9% |
| call_mix（通常） | 258.758 ± 1.293 | 165.647 ± 23.514 | 36.0% |
| call_mix（インライン化なし） | 396.490 ± 6.502 | 290.957 ± 4.559 | 26.6% |

パッチありのinline/callにも外れ値があり、標準偏差を併記する。
10万回も記録したが、パッチありinlineは1回の大きな外れ値により17.581 ± 18.879 msとなったため、
短いケースから一律の改善率は主張しない。
[両入力の全サンプル、交互比較のharness、バイナリ情報と検証結果](../benchmark/results/while_final_compiler_comparison_2026-11-04.json)。

最終ソースは、パッチなし・ありの双方で117 tests / 10,893 assertionsが成功した。
型チェックも成功した。パッチあり生成Cでは、追加のfetchルート・setjmp・volatileが0で、
関数のルート登録と境界・overflowチェックが残っていることを再確認した。
Warditeの変更自体はwhile化であり、これらの追加の短縮率はローカルSpinelパッチの効果として扱う。
