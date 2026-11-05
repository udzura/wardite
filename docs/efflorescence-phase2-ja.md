# Efflorescence VM — Phase 2

[English](efflorescence-phase2.md) · [Phase 1](efflorescence-ja.md)

Phase 2では、MIRを実行するときのオーバーヘッドを減らします。
Warditeのデフォルトは引き続き既存のスタックVMです。
`--new-engine` でEfflorescenceを選択すると、以下の最適化が有効になります。
現在の命令対応範囲は[M1の実装記録](efflorescence-m1.md)を参照してください。到達不能なコードやエクスポートされていない関数も含め、
未対応命令は引き続き明示的な例外になります。

## パイプラインと切り替え

```text
Wasm → Translator → 意味論を表すMIR（保持）
                  → CopyPropagation
                  → ImmediateSpecialization
                  → BranchFusion
                  → Superinstructions
                  → Inlining → 変更した関数にローカルなパスを再適用
                  → 最適化済みMIR（保持）
                  → 必要に応じて計測命令を挿入
                  → Lowerer → 実行用の整数配列 → VM
```

ローカルなパスは関数単位で動作し、Inliningはモジュールのスナップショットを参照します。`Optimizer` は元のMIRをコピーしてから変更するため、
変換直後のMIRはそのまま残ります。
`Rewrite` は変更前後の命令位置の対応表を作り、命令列を書き換えるたびに分岐先を補正します。
`Analysis` はBasic Blockの入口を求め、関数全体でレジスタの定義回数と使用回数を数えます。

```sh
# デフォルトの最適化済み実行
ruby -Ilib exe/wardite --new-engine --no-wasi --invoke call_mix build/benchmark/i32_mix.wasm 100000 123

# 最適化を個別に無効化。複数指定する場合はオプションを繰り返す
ruby -Ilib exe/wardite --new-engine --mir-disable copy --mir-disable frames --no-wasi --invoke call_mix build/benchmark/i32_mix.wasm 100000 123

# 6つの最適化をすべて無効化したMIRをflatへ変換して実行
ruby -Ilib exe/wardite --new-engine --mir-disable all --no-wasi --invoke call_mix build/benchmark/i32_mix.wasm 100000 123

# 最適化前後のMIR表示と詳細計測。性能計測とは別に実行する
ruby -Ilib exe/wardite --new-engine --mir-dump --mir-profile --no-wasi --invoke call_mix build/benchmark/i32_mix.wasm 10 123
```

`copy`、`immediate`、`branch`、`superinstruction`、`inline`、`frames` を個別に無効化できます。
不明な名前を指定するとエラーになります。
MIR用のCLIオプションには `--new-engine` が必要です。
表示・計測オプションを明示的に指定しなければ、checksumの出力形式は変わりません。

```ruby
instance = Wardite.new(path: "build/benchmark/i32_mix.wasm",
  enable_wasi: false, engine: :efflorescence,
  disabled_optimizations: [:superinstruction], mir_profile: true)
vm = instance.runtime
vm.call("call_mix", [1000, 123])
puts vm.dump_mir
puts vm.metrics.report
```

`BinaryLoader.load_from_buffer` でも同じキーワード引数を使えます。
`VM.new` を直接呼ぶ場合は、`disabled_optimizations:` と `profile:` を指定します。

## 最適化の内容と正しさを保つ条件

| 最適化 | 実装内容 | 正しさを保つ条件 |
| --- | --- | --- |
| COPY削減 | 直後のCOPYの格納先へ演算結果を直接書き込む。同じBasic Block内でコピー元を伝播し、自己コピー・読み出されないコピー・読み出す前に上書きされるコピーを削除する | 演算結果の一時レジスタは、関数全体で定義・使用がそれぞれ1回であること。吸収するCOPYへ途中から分岐できないこと。値ソースの対応表はBasic Blockの境界でリセットし、参照元を上書きしたら対応を無効化する。COPYの生存解析では、分岐の先ですべてのレジスタが使われると保守的に扱う |
| 即値化 | ADD/SUB/MUL/XOR/SHL/SHR_Uのオペランドに、書き換えない定数レジスタの値を直接埋め込む | 左辺の定数を右辺へ移してよいのはADD/MUL/XORだけ。シフト量のマスクと、16bitごとに分割する乗算処理は維持する |
| 分岐融合 | `I32_EQZ tmp, src; BR_IF tmp, pc` を `BR_IF_ZERO src, pc` にする | 一時レジスタがローカル変数ではなく、定義・使用が各1回であること。2命令目へ途中から分岐できないこと |
| Superinstruction | 即値による論理右シフト／左シフトと、元の値とのXORを融合する | 中間値の定義・使用が各1回で、XORがBasic Blockの入口ではないこと。ベンチマークの関数全体を置き換える専用命令は使わない |
| Inlining | 短い直線状のleaf関数を展開し、有効なローカルパスを再適用する | 呼び出し先は8命令・32スロット以内。レジスタを新しく割り当て、引数のスナップショットを保ち、各呼び出し位置でローカルを0初期化する。分岐・trap・内部CALLは対象外。1回のスナップショットに限定し、呼び出し元ごとの増加を整理前で64命令・256スロット以内に抑える。`--mir-disable inline` で無効化できる |
| フラット化（常時実行） | opcodeとオペランド3個を、固定幅4の整数配列に並べる | 分岐先の命令番号は4倍して配列上のオフセットに変換する。CALLの引数は別の `CallSite` に保持し、解決済みの呼び出し先と引数レジスタ配列を参照するため、引数の数は固定幅に制限されない |
| フレーム再利用 | 1回の公開API呼び出しが所有する、関数ごとの空きフレーム一覧を使う | 実行中のフレームは再利用しない。初回はレジスタのテンプレートを複製し、再利用時は非引数ローカルだけを0に戻してPC・戻り値の格納先を初期化する。引数はCALLで設定し、定数は保持する。一時値はロード時の定義解析で使用前の代入を保証する。再帰や重なり合う公開API呼び出しでも、実行中のフレームは独立させる |

実行器はflatに統一し、`--mir-disable all` の場合もLowererによる変換を必ず行います。
`flat`の最適化スイッチとsemantic実行器は削除しました。
意味MIRと最適化済みMIRは、検証・書き換え・表示用に保持します。
`--mir-disable all` は6つの任意の機能を無効化してからflatへ変換するモードであり、
Phase 1のバイナリそのものではありません。以下の過去の計測値は当時の設定による記録です。
比較スクリプトでは、コミット `67fbfae` を独立してビルドしたものも基準として使えます。

flat実行器には `while true` を使い、Spinelによる `Kernel#loop` のStopIteration捕捉と、
それに伴うvolatile変数の生成を避けます。StopIterationを含む命令実行中の例外はRubyの呼び出し元へ伝播します。
命令フェッチの `Array#fetch` と境界検査、整数overflowチェックは維持します。
CIで使う未改造のSpinelで動作します。fetchの重複GCルートを省くSpinelパッチは、独立したコンパイラ側の実験です。
[生成Cの調査と測定結果](efflorescence-generated-c-guards.md)に詳細を記録しています。

## MIRの表示と計測

`VM#semantic_ir` は変換直後のMIR、`optimized_ir` は最適化パスを適用したMIRです。
`ir` は実際に実行するMIRで、詳細計測を指定した場合はPROFILE命令も含みます。
フラットな命令列は `Function#bytecode` に保持します。
通常実行では、MIR命令ごとに計測フラグを判定したり、カウンタを更新したりしません。

詳細計測では、各MIR命令の前にPROFILE命令を挿入し、分岐先もその計測命令に合わせて補正します。
ディスパッチ回数には、計測用命令自身の実行は含めません。
レジスタの読み書き回数はMIRのオペランドアクセスを数えたもので、内部呼び出しの引数コピーと
戻り値の格納は含みますが、フレーム初期化・Rubyとの境界での準備・命令の読み出しは含みません。
ハードウェア上のメモリアクセス回数ではありません。
`metrics` は直近の公開API呼び出しの結果を保持します。
性能を測るプロセスでは、詳細計測を有効にしません。

以下はインライン化を追加する前のPhase 2初期のカウンタです。
`rounds=100000, seed=123` では、両方のエクスポート関数が符号なし整数 `3870791521` を返します。

| 指標 | inline 最適化なし | inline 最適化あり | call 最適化なし | call 最適化あり |
| --- | ---: | ---: | ---: | ---: |
| ディスパッチ回数 | 1,300,005 | 700,003 | 1,600,005 | 900,003 |
| COPY実行回数 | 300,002 | 1 | 400,002 | 1 |
| レジスタ読み出し | 1,900,005 | 600,003 | 2,200,005 | 800,003 |
| レジスタ書き込み | 1,100,003 | 500,001 | 1,400,003 | 700,001 |
| Frame生成数 | 1 | 1 | 100,001 | 2 |

3関数全体の静的なMIR命令数は35→20、COPY命令数は11→2になります。
レジスタ数は37のままです。この段階では、使わなくなった一時値や定数のスロットは詰め直しません。
現在はインライン化により、静的MIRが23命令・49スロットになり、`call_mix` のディスパッチは
`inline_mix` と同じ700,003回、Frame生成と関数への入場は各1回です。
[インライン化の計測と制約](efflorescence-inlining.md)を参照してください。

Spinelの生成Cコードも、以下の手順で確認しています。

```sh
spinel -I lib --strict-require -O2 -c exe/wardite -o build/benchmark/phase2-wardite.c
```

フラットな命令列とフレームのレジスタは、どちらも `sp_IntArray*` になっています。
オペランドの読み出しには `sp_IntArray_get` を使い、ディスパッチ時には `Instruction#[]` を呼び出しません。
オブジェクトのメタデータや、Frame／CallSiteの一覧には汎用配列が残る場合があります。

### 整数リテラルによるディスパッチ

実行ループでは、意図的に `when Opcode::COPY` ではなく
`when 0 # Opcode::COPY` と書いています。
検証したSpinelの[整数caseの高速化処理（`emit_case`）](https://github.com/matz/spinel/blob/master/src/codegen_stmt.c#L11032-L11101)は、
AST上の整数リテラルを条件にしています。値が整数であっても、定数の参照はこの条件を満たしません。
整数リテラルにすると、定数との比較を並べた処理から、opcode 0〜22を扱うCの `switch` に変わります。

MIRの生成と最適化パスでは、引き続きOpcode定数を使います。
ディスパッチの各ラベルにはOpcode名をコメントで残し、数値と定数の一致、全opcodeへの対応を回帰テストで確認します。
ネイティブテストではCLIをCに変換し、flat実行器で `switch` が生成されることも確認します。
Phase 2の追加変更時点（当時は両実行器が存在）の検証では、**88テスト、4,466 assertions、失敗・エラー・省略はいずれも0件**でした。
型チェックも成功しています。

```sh
ruby benchmark/compare_dispatch.rb 100000 123
# Spinelだけを対象に、必要なら処理量を増やして計測
RUNTIMES=Spinel ruby benchmark/compare_dispatch.rb 1000000 123
```

この比較では、現在のソースの一時コピーから定数ラベルのディスパッチを再現し、独立してビルドします。
ほかの最適化と公開APIの呼び出し境界は同じに保ち、定数版と整数リテラル版を交互の順序で計測します。
計測前と、各サンプルの実行時にchecksumを照合します。
結果は `build/benchmark/dispatch.json` に保存し、一時的な比較用ソースは計測後に削除します。
[ディスパッチの比較結果](../benchmark/README.md#integer-literal-dispatch)も記録しています。
Spinelで処理量を増やした計測（`rounds=1000000, seed=123`）では、実行部分が
inlineで100.43→90.68 ms、callで229.76→209.93 msとなり、それぞれ9.7%、8.6%短縮しました。
ウォームアップ2回の後に、5回計測した平均値です。

## 検証とベンチマーク

```sh
bundle exec rake check
make spinel
WARDITE_SPINEL_BIN="$PWD/build/wardite" bundle exec rake test
ruby benchmark/compare_optimizations.rb 100000 123
ABLATIONS=1 RUNS=3 WARMUPS=1 ruby benchmark/compare_optimizations.rb 100000 123
```

受け入れ用WAT全体を変更せずに使い、元の8組すべての入力を、デフォルト設定、各最適化の個別無効化、
全最適化の無効化で実行します。CRubyとSpinelの両方を対象にしています。
追加のテストでは、上書き・分岐・呼び出し・ループをまたぐスナップショット、融合候補の途中への分岐、
後で使われる中間値、符号なし整数の乗算、シフト量のマスク、オペランド順序、再利用時のローカル変数初期化、
再帰、公開API呼び出しの重なり、カウンタの正確な値を確認します。
既存のスタックVMのテストも、引き続き実行します。

その後の[フレーム初期化の軽量化](efflorescence-register-initialization.md)では、合流点・バックエッジを含む
レジスタの定義解析も追加しました。この改修後の全体検証は、Spinelネイティブ版を含めて95テスト・5,009 assertionsが成功しています。
続く[CALL/RETURNの型情報を保つ改修](efflorescence-call-types.md)では、生成CでFrame・pool・CallSite表の型を具体化しています。
MIR命令は変更せず、96テスト・5,021 assertionsが成功しました。
続く[引数搬送の軽量化](efflorescence-call-transfer.md)では、flat CALLの第4スロットを1引数のソース番号に使い、
一般の引数コピーを実行器の外へ分離し、poolのインデックスを保持します。99テスト・5,703 assertionsが成功しました。
続く[オペランド読み出しの軽量化](efflorescence-operand-decoding.md)では、4ワードのPC表現を保ちながら使わないb/cを読み出さなくしました。
`-O2` 固定で比較し、105テスト・5,741 assertionsが成功しています。
続く[小さな関数のインライン化](efflorescence-inlining.md)では、独立パスと有効・無効の比較を追加し、
112テスト・9,028 assertionsが成功しています。

2026年11月4日に、CRuby 4.0.9でSpinelのネイティブテストも有効にして全体を検証し、
**88テスト、4,466 assertions、失敗・エラー・省略はいずれも0件**でした。
`bundle exec rake check` も成功しています。
Spinelは `2026.10.25+1967`（`6e7fc1355`）を使い、`-O2` とデフォルトの整数オーバーフローチェックでビルドしました。
[Phase 1との性能比較と、各最適化を無効化した場合の計測結果](../benchmark/README.md#phase-2-sample-2026-11-04)を記録しています。
デフォルト設定の採用判断ではSpinelでの効果を重視しています。
CRubyやYJITでは、個々の最適化が同じ程度に効くとは限りません。

比較スクリプトは、計測対象のすべてのCLIと実行時間計測用プログラムについて、
剰余演算に基づく独立参照実装との一致を確認してから時間を測ります。
CLIプロセス全体の時間に加え、ロード・MIR変換・実行の各時間と、CRubyでの実行中のallocation数を記録します。
時間計測用プログラムはCLIと同じ `call` APIを使い、Rubyへ返す際のboxingも含めます。
Spinelのallocation数はCRubyから推定せず、取得不能として扱います。
生のサンプル、平均値、opcodeごとのカウンタ、静的なMIRの概要は
`build/benchmark/optimizations.json` に保存します。
`ABLATIONS=1` で、各最適化を1つずつ無効化した構成も比較できます。

各処理の時間は、CLIとは別にコンパイルしたプログラムで計測するため、足し合わせてもCLI全体の時間とは一致しません。
Spinelの型推論結果も、入口のプログラムが異なることで変わる場合があります。
ウォームアップは別プロセスで行うため、YJITのコンパイルもサンプルごとに発生します。
デフォルトでは、ウォームアップ2回の後に5回計測します。

Phase 1そのものと比較する場合は、コミット `67fbfae` のソースを別ディレクトリに用意してビルドし、
`PHASE1_ROOT`、`PHASE1_BIN`、`PHASE1_WORKER` を指定してください。
手順は[ベンチマークの説明](../benchmark/README.md)にあります。

## 今後の実験

アキュムレータ、Basic Block単位のディスパッチ、定数畳み込み、レジスタの詰め直し、共有レジスタスタック、
Ruby／ネイティブコード生成は実装していません。今回作った独立したパスの仕組みを使い、今後試せます。
対応するWasm命令の拡張は別の作業です。新しい命令を最適化の対象にする前に、
その命令のレジスタの読み書きと制御フローへの影響を定義する必要があります。

設計では、[WasmKitのレジスタ型インタプリタ](https://github.com/swiftwasm/WasmKit/blob/main/Documentation/RegisterMachine.md)と、
[Wasmi 2.0の最適化解説](https://wasmi-labs.github.io/blog/posts/wasmi-v2.0/)を参照しました。
これらのネイティブなディスパッチ方式やアキュムレータがRubyでも同じコストになるとは仮定せず、
今回実装した方式をCRubyとSpinelで検証しています。
