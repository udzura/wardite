# ADR 0022: 関数のMIRを初回の呼び出しで仕上げる

- **状態** 提案
- **日付** 2026-11-17
- **基準** Wardite 1.2.2 `5baaf38`
- **関連** [ADR 0010](0010-efflorescence-mir2-cache-function-restore.md)（関数単位の復元）、[ADR 0012](0012-efflorescence-startup-snapshot.md)、[ADR 0015](0015-efflorescence-selective-inline-snapshots.md)、[ADR 0018](0018-efflorescence-real-workload-measurement.md)（計測の基準）、[ADR 0019](0019-efflorescence-startup-quick-wins.md)、[ADR 0021](0021-efflorescence-optimize-real-functions.md)

## 決定

ロード時に全関数で行っている最適化、RegisterValidation、loweringを、関数が初めて呼ばれたときに行う。これを段階Aとする。Wasmとしての検証は、今と同じくロード時に全関数で行う。翻訳（Translator）はロード時に全関数で行い続ける。

初回の呼び出しで関数を仕上げる仕組みには、MIR2キャッシュの関数単位の復元（[ADR 0010](0010-efflorescence-mir2-cache-function-restore.md)）が使う `FramePool#acquire` のフックを使う。

段階Aの計測の後、翻訳も初回の呼び出しへ遅らせるかを判断する。これを段階Bとする。Wasmの検証をロード時より後に遅らせることと、コードセクションのデコードを遅らせることは、この ADR の対象外とする。

## 背景

### 実行される関数は定義された関数の一部である

wardite-benchesのWASIサンプルで、定義された関数と、実際に実行された関数を数えた。CRubyでMIR2キャッシュをヒットさせ、実行後も `cache_pending` のまま残った関数を、実行されなかった関数とした。bytecodeの長さは、実行された関数の合計を全関数の合計で割った。

| ワークロード | 定義された関数 | 実行された関数 | 実行された関数のbytecodeの割合 |
|---|---:|---:|---:|
| `base64_codec encode` | 284 | 56 | 32% |
| `base64_codec decode` | 284 | 56 | 35% |
| `png_grayscale` | 391 | 90 | 54% |

呼ばれなかった関数の多くは、Rustの標準ライブラリに由来する整形やpanicの経路だと見ている。これは関数名を確かめていない推測である。今の実装は、呼ばれない関数も含めて、全関数をロード時に最適化し、検証し、loweringする。

### 段階Aで遅らせる処理はロードとMIR準備の2〜3割にあたる

既定サイズの入力では、ロードとMIR準備がプロセス全体の時間の3割（Base64）から6割（PNG）を占め、WarditeのRSSは46〜105 MiBになる（[ADR 0018](0018-efflorescence-real-workload-measurement.md)）。

[ADR 0019](0019-efflorescence-startup-quick-wins.md) のプロファイルで、`load_from_buffer` を含むサンプルに対する割合を見る。Translatorが38〜39%、RegisterValidationが12〜13%、`IR#copy` が11%、Lowererが5〜6%、デコードが21〜23%だった。`build_mir` 全体は76〜77%で、残りの約8%に最適化のパスなどが入る。段階Aで遅らせるのは、`IR#copy` を除く最適化、RegisterValidation、loweringで、合わせて2〜3割である。`IR#copy` は ADR 0019で減らす。段階Bで遅らせる翻訳は約4割である。

呼ばれない関数の分だけ、この時間とMIRのメモリが減る。最初の表から、bytecodeの量で見てBase64では約3分の2、PNGでは約半分が対象になる。

### 関数単位で仕上げる仕組みは既にある

MIR2キャッシュがヒットすると、本体のない関数を `cache_pending` として作り、初回の呼び出しで復元する（[ADR 0010](0010-efflorescence-mir2-cache-function-restore.md)）。復元のフックは `FramePool#acquire`（[ir.rb](../../lib/wardite/efflorescence/ir.rb#L1230)）にある。フレームを再利用するときは通らないので、命令の実行ループに分岐は増えない。

次の経路は、すべてこのフックを通る。

- 直接の `CALL` と `CALL_INDIRECT`
- 公開関数の呼び出し、start関数、ホストからの再入（`VM#execute`）
- 起動スナップショットからの再開（`VM#resume`）

関数間の依存は少ない。直接 `CALL` の翻訳に要るのはcalleeの `FunctionEntry`（シグネチャ）だけで、`call_indirect` に要るのは型とtable 0の存在だけである。Lowererはcalleeの `Function` を `CallSite` に入れるが、実行時に使うのは `pool_index` だけである。calleeのMIR本体を必要とするのはInliningだけである。

## 段階A：最適化・検証・loweringを遅らせる

ロード時の処理は、デコードと翻訳までにする。Wasmの型検査は翻訳の中で行われる（`Translator#pop_typed` など）ので、ロード時に全関数で行われ続ける。各関数のsemantic MIRを持ち、仕上げていない関数に印を付ける。関数が初めて呼ばれたら、次の順にその関数を仕上げる。

1. 局所最適化（`Optimizer#optimize_function`）
2. Inlining。下の[Inliningの扱い](#inliningの扱い)に従う
3. RegisterValidation
4. Instrumentation（`--mir-profile` のときだけ）
5. lowering

仕上げた結果は、印を付けた `Function` に書き込む。`CallSite` などがこの `Function` を参照しているので、オブジェクトを置き換えない。途中で例外が出た場合は、半端に埋まった関数を公開しない。MIR2キャッシュの復元と同じ扱いにする（[mir_cache.rb](../../lib/wardite/efflorescence/mir_cache.rb#L302)）。

`FramePool` の `@cache` は `MIRCache?` 型である（[ir.rb](../../lib/wardite/efflorescence/ir.rb#L1219)）。キャッシュからの復元と、その場での仕上げの両方を受け持つ1つの具象クラスに置き換える。Spinelでは、ここに異なるクラスの値を入れると型が多相になるためである。

### Inliningの扱い

eagerの実装と同じbytecodeを作る。起動スナップショットは、保存したpcとレジスタ数がbytecodeと一致することを検査する（[snapshot.rb](../../lib/wardite/efflorescence/snapshot.rb#L197)）。MIR2キャッシュとの互換も、同じbytecodeであることに依存する。

今のInliningは、全関数を局所最適化した後で、eligibleなcalleeの複製を作り、callerに展開する（[ADR 0015](0015-efflorescence-selective-inline-snapshots.md)）。eligibleなcalleeは、8命令以下・32レジスタ以下で `CALL` を含まないleaf関数である。そのため展開は1段で止まる。

段階Aでは、callerを仕上げるときに、直接呼ぶcalleeを局所最適化してeligibleかを判定する。局所最適化した結果は関数ごとに1回だけ作って覚えておき、calleeを自分で仕上げるときにも使う。eligibleなcalleeはleafなので、この判定は1段で止まる。

### 全関数をまとめて仕上げる場面

次の場面では、今と同じくロード時に全関数を仕上げる。

- `--mir-cache` を指定してキャッシュがミスしたとき。`MIRCache#write_ir` は全関数のbytecodeを必要とする
- `--mir-cache-eager`
- `--mir-dump`。今と同じく `restore_inspection_ir` で全体を作り直す
- 起動スナップショット。`--mir-cache` を必要とするので、上の条件に含まれる

テストのためにも、全関数を仕上げる内部のメソッドを用意する。ロード直後に `bytecode` を読むテストは、このメソッドを呼ぶか、eagerな構成で実行する。

## 段階B：翻訳も遅らせる（段階Aの計測後に判断する）

段階Bでは、ロード時のTranslatorを、MIRを残さずにWasmの型検査だけを行うモードで動かす。関数が初めて呼ばれたときに、改めて翻訳する。

段階Bには次の課題がある。段階Aの計測で、翻訳がロード時間に占める割合を確かめてから判断する。

- Translatorは翻訳時にStoreを読む。`store.funcs`、globalの型と可変性、memoryとtableの有無である（[translator.rb](../../lib/wardite/efflorescence/translator.rb#L255)）。ホストはロード後に `Store#funcs` を書き換えられる（[vm.rb](../../lib/wardite/efflorescence/vm.rb#L31)）。ロード時の状態を捕まえて、翻訳に渡す必要がある。
- 実行される関数は2回翻訳される。実行される関数が多いモジュールでは、合計の時間が増える。

## 守る契約

- Wasmの検証はロード時に行う：不正な関数と、Efflorescenceが対応していない命令は、呼ばれない関数にあってもロード時に拒否する（[efflorescence-ja.md](../efflorescence-ja.md)）。この振る舞いを固定している既存のテストはそのまま通す。例は [efflorescence_m1_loader_test.rb](../../test/efflorescence_m1_loader_test.rb) と [efflorescence_m4_test.rb](../../test/efflorescence_m4_test.rb)。
- bytecodeはeagerな実装と同じにする：MIR2キャッシュのフォーマットと `CODE_VERSION` は変えない。
- RegisterValidationは省略しない。仕上げの時点で検証に失敗した場合は、Wardite自身の不具合として、今と同じ例外クラスで知らせる。変わるのは、この例外が起きる時点がロード時から初回の呼び出し時になることだけである。
- 仕上げは関数ごとに1回だけ行う。ホストからの再入の途中で同じ関数が呼ばれても、二重に仕上げない。
- `--mir-disable` と `--mir-profile` の意味を変えない。

## 検証

- eagerとlazyで、全関数のbytecode、side table、レジスタ数が一致することを確かめる。[efflorescence_mir_cache_test.rb](../../test/efflorescence_mir_cache_test.rb) のeagerと遅延復元の比較（Inliningを含む）と同じ形にする。fixtureには、wardite-benchesのWASIサンプルとruby.wasmを加える。
- 呼び出しの経路ごとに、初回で仕上がることを確かめる。経路は `CALL`、`CALL_INDIRECT`、公開関数、start関数、ホストからの再入、スナップショットからの再開である。
- 仕上げの途中で例外が出たときに、半端な関数が残らないことを確かめる。
- `bundle exec rake test`、`bundle exec rake check`、`make spinel-test RUBY="bundle exec ruby"`、`bundle exec rake parity` を実行する。`WARDITE_VERIFY_MIR_CACHE_PARITY=1` でも実行する。

## 計測と受け入れ条件

[ADR 0018](0018-efflorescence-real-workload-measurement.md) の手順と条件に従う。一次指標は、ロードとMIR準備の時間（`WARDITE_TRACE` の `load_from_buffer`）とRSSである。

初回の呼び出しで仕上げる時間は、ロードの時間から実行の時間へ移る。そのため、プロセス全体の時間も並べて比べる。採用の条件は、既定サイズの入力でプロセス全体の時間とRSSが減り、16倍の入力で悪化しないことである。
