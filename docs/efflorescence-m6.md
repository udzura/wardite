# Efflorescence M6 の対応範囲と検証

[ADR 0006](adr/0006-efflorescence-m6-coverage-parity.md) の実装記録。対象はM0が定めた旧VMの188命令と、Efflorescenceが追加した新形式EHの3命令。M6開始時に共有デコーダーと旧VMの実行経路を再照合し、M0から対象の増減がないことを確認した。対応範囲とM0当時の履歴は [M0一覧](efflorescence-coverage-ja.md) に分けて記録した。

## 命令ごとの実行証拠

[命令manifest](../test/support/efflorescence_opcodes.tsv) はopcode、共有デコーダーの内部名、導入段階、TranslatorとMIRの経路、正常・境界・trapのfixture ID、参照エンジン、制限を結ぶ。M0一覧やデコーダーとの欠落・重複をテストで検出する。

[manifest runner](../test/support/run_efflorescence_manifest.rb) は各ケースのWasmをコンパイルし、CRubyとSpinelで `--mir-disable all` 相当のMIRをprofilingする。各fixtureの戻り値かtrap、メモリのページ数・長さ・対象バイト、global、ホストイベント、stdoutを照合する。対応するMIR命令がdispatchされなければ失敗する。定数は初期レジスタを読んだ結果のビットとRETURNを照合する。独立したMIR命令を持たない構文では、共有デコーダーのopcodeと、該当する制御経路に置いたglobal更新の実行結果を照合する。

| 対象 | 実行結果 |
|---|---|
| M0の188命令と新形式EH 3命令 | CRuby・Spinelそれぞれ436 fixture |
| Wasmtime 49.0.0（`17830bd3c`） | 同じ436 fixtureの結果またはtrap種別 |
| 旧VM | CRuby・Spinelそれぞれ428比較 |
| 旧VMとの差 | CRuby 42件、Spinel 47件。旧VMの観測値と理由を固定 |

各エンジンと各fixtureに別のインスタンスを割り当て、連続呼び出しを調べるケースだけ同じインスタンスを使う。Wasmtimeには `-W exceptions=y` を指定した。floatはWasm内で整数へreinterpretして比較する。bit保存は完全一致で判定し、演算NaNは入力に応じてcanonical NaNまたはquiet NaNの集合を判定する。既存のspec runnerは非i32の公開引数、複数結果、NaN、trapの検証に制約があるため、この比較には専用runnerを使った。

[旧VMの差分表](../test/support/efflorescence_legacy_differences.tsv) に、境界外storeとbulk memoryの副作用、fillの下位8bit、符号付きゼロとnearest、符号拡張、f32の中間丸めとNaN payload、Spinelの旧VMにおけるbulk memoryの制約を記録した。差分ケースではWasmtimeまたは独立期待値をEfflorescence側の基準とする。旧VMの通常のload境界失敗と未初期化の間接呼び出しは同じtrap種別へ正規化する。EHの8 fixtureはEfflorescenceとWasmtimeで検証する。

共有デコーダーでは、死んだコードにも現れるs32の幅超過と、未参照globalの初期値の型不一致を拒否する。型、index、featureの拒否を実行経路と分けて検証した。

## 複合実行と公開境界

- active data・global・elementをstartから読み取るケースを両エンジンで比較した。data、element、不正なstartシグネチャ、未exportの不正命令・型・index、multi-value、欠落importはEfflorescenceでstart前に失敗する。旧VMの欠落importは呼び出されるまでリンクを遅延するので、旧VMが先にstartを実行するケースも照合した。
- grow後のpassive data転送、重複copy、globalのsnapshot、インスタンス分離を検証した。trapの直前までに行われたメモリとホストの副作用、およびtrap後の再呼び出しを確認した。Spinelの旧VMでのbulk memoryと、Efflorescenceの異常後の再呼び出しは拡張側の期待値で検証した。
- i32/i64/f32/f64とvoid、定義関数とimportのexport、forward callと再帰、直接・間接呼び出し、混在host ABI、再入、型と個数の拒否を確認した。混在EHはcall越しのcatch、throw_ref、未捕捉時のpayload、数値trapの非捕捉、フレーム再利用を含む。
- 既定、all無効、copy、immediate、branch、superinstruction、inline、framesの個別無効を両ランタイムで実行した。CLIではengine選択、start後のinvoke、既存結果形式、型付きMIR dumpとprofileを確認した。floatを使うcallerとcalleeは双方ともinliningから除外され、同じ条件のi32関数はinliningされる。
- CRubyでM3の `fd_write` と `proc_exit`、M4の `path_open` を実行した。SpinelではWASIの有効化が明示的に拒否され、通常のhost callbackは利用できる。

i32のunboxed結果はunsigned、i64はsigned、f32/f64はRuby Float、voidはnil。boxed結果は数値型に応じたwrapperを返す。float引数はFloatまたは対応するwrapperを受け付け、f32は境界でbinary32へ丸める。内部MIRでは数値を整数carrierで転送する。公開Ruby Floatを経由したNaN payloadの完全保持は保証しない。詳細は [M5のAPIと値の経路](efflorescence-m5.md) を参照。

対象はmemory 0のmemory32とtable 0のfuncref間接呼び出し、数値シグネチャと単一関数結果まで。関数multi-value、block引数、typed select、GC、SIMD、table操作命令、data.drop、legacy EH、tag import/export、ホスト例外のWasm EH化は対象外。既定エンジンはStack VMで、Efflorescenceは `--new-engine` または `engine: :efflorescence` で選ぶ。

## 再現コマンド

```sh
bundle exec rake test
bundle exec rake check
make spinel-test RUBY="bundle exec ruby"
bundle exec rake parity
bundle exec ruby -Ilib benchmark/validate_m5.rb
```

検証環境は CRuby 4.0.9、Spinel `6f1a2c259`（`-O2`、既定overflowチェック）、wasm-tools 1.218.0、Wasmtime 49.0.0。M6の実行コードと受け入れ試験は `e0437f7`。M6eではdispatchを調整し、全構成の検証と再現コマンドを追加した。CRubyのsuiteは249件、26,409 assertionsで失敗0件。そこで省略された73件はすべてSpinel専用で、Spinelのsuiteは73件、2,534 assertionsを省略なしで実行した。manifest runnerと型チェックも失敗0件。M5の参照比較はnearestの0.5直前・直後を加えた固定385件と固定seedの560件で一致した。

## 性能の再計測

M4 → M5の基準比較は [M5の性能記録](efflorescence-m5.md#性能) に記載した。M6ではM5の `e31d767` と比較し、同じi32・i64・floatのWasm、同じchecksum、同じruntimeで再計測した。100,000 roundsのi32と20,000 roundsのi64・floatを、2回ウォームアップして5回計測した。以下はロードと実行の中央値（ms）。計測中はprofilingとinliningを無効にした。

```sh
baseline=$(mktemp -d)
git archive e31d767 | tar -x -C "$baseline"
RUNS=5 ruby --disable-yjit -Ilib benchmark/measure_m4.rb "$baseline" M5
```

| ケース | CRuby ロード | CRuby 実行 | Spinel ロード | Spinel 実行 |
|---|---:|---:|---:|---:|
| `inline_mix` | 1.629 → 1.534 | 64.230 → 65.050 | 0.333 → 0.327 | 2.176 → 2.139 |
| `call_mix` | 1.626 → 1.615 | 114.749 → 114.905 | 0.346 → 0.333 | 4.102 → 4.492 |
| `direct_host` | 1.570 → 1.505 | 91.188 → 92.551 | 0.344 → 0.352 | 6.927 → 6.978 |
| `indirect_host` | 1.623 → 1.516 | 136.280 → 136.049 | 0.351 → 0.353 | 12.767 → 12.826 |
| `alu` | 1.469 → 1.641 | 55.768 → 55.437 | 0.362 → 0.373 | 1.106 → 1.117 |
| `division` | 1.578 → 1.328 | 223.015 → 223.906 | 0.360 → 0.374 | 2.745 → 2.835 |
| `memory` | 1.613 → 1.617 | 42.484 → 42.363 | 0.381 → 0.381 | 2.655 → 2.659 |
| `mixed_call` | 1.481 → 1.482 | 44.672 → 44.799 | 0.358 → 0.360 | 1.527 → 1.507 |
| `float_alu` | 1.276 → 1.359 | 42.272 → 44.743 | 0.326 → 0.320 | 10.734 → 11.552 |
| `float_convert` | 1.551 → 1.373 | 60.241 → 63.373 | 0.325 → 0.314 | 6.155 → 6.088 |
| `float_mixed_call` | 1.336 → 1.493 | 52.986 → 55.295 | 0.344 → 0.312 | 9.990 → 10.818 |

### 整数dispatchの性能差

M5追加後のSpinelでは、M4との同時比較で100,000回の間接host呼び出しが17.428 → 18.005 msだった。整数命令を実行する比較用ビルドを使い、1,000,000回の間接host呼び出しで変更箇所を切り分けた。2回ウォームアップして7回計測し、ビルドの順序を交替した。

| 比較用ビルド | 中央値 ms |
|---|---:|
| M4 | 174.681 |
| M6の分岐集約前 | 180.091 |
| floatのdispatch分岐を除いた整数専用ビルド | 175.307 |
| M4のhost kernelを使ったビルド | 178.722 |

floatの分岐追加が主な増加要因だったため、M6eではALUの型情報を使ってfloat命令の処理を集約し、`execute_float` から実行する構成にした。主dispatchの整数・制御命令は従来のliteral switchを使う。生成Cの検査では主dispatchのframe stackと、float側のregisterが整数配列を維持することを確認する。float命令も同じflat bytecodeとbit carrierを使い、命令ごとのprofilingと型検証を受ける。

集約後のM4との再比較では、100,000回のSpinelのdirect hostが6.860 → 6.853 ms、indirect hostが12.556 → 12.723 msだった。indirect hostの範囲は12.133〜12.717 msと12.509〜13.110 msで重なった。i32の間接hostにはM4から約1.3%の差が残る。主dispatchに追加したfloat分岐を集約して整数経路への影響を抑え、float命令はhelper呼び出しと型情報参照の費用を負担する構成にした。今回のM5との同時比較では、float_aluの実行中央値はCRubyで42.272 → 44.743 ms、Spinelで10.734 → 11.552 msだった。f32/f64を使う関数の最適化除外と、このdispatch費用を制約として記録する。

各表ではビルドの順序を交替して同時比較した。別計測の絶対時間は実行時の負荷とCPUの状態で変動する。

```sh
baseline=$(mktemp -d)
git archive e992d2c | tar -x -C "$baseline"
RUNS=7 ruby --disable-yjit -Ilib benchmark/measure_m4.rb "$baseline" M4 M6
```

CRubyのfd_writeを30,000回実行し、計120,000 byteとerrnoを確認した。最終コードの中央値は専用ABIで96.274 ms、boxed ABIで128.477 ms。割り当てはそれぞれ90,014件、570,014件だった。公開float境界のboxing費用は [M5の境界計測](efflorescence-m5.md#性能) に記録した。内部CALLではwrapperを生成しない。
