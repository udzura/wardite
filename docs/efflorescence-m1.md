# Efflorescence M1: i32・制御構造・新形式EH

[ADR 0001](adr/0001-efflorescence-m1-control-and-eh.md)のM1a〜M1dを実装した。
既存M0の21命令に、i32比較・演算・符号拡張、if/else/select/br_tableの28命令、
さらに`try_table`、`throw`、`throw_ref`を追加する。エンジンの選択は引き続きopt-inの
`--new-engine` / `engine: :efflorescence`。デフォルトのstack VMにはEHを追加しない。

## 対応する値と例外

- 関数はi32引数、voidまたは単一i32結果。直接call、再帰、相互再帰に対応する。
- block/if/try_tableは引数なし、i32/exnrefの結果列。loopは引数なしで、結果列を許す。
  loop先頭への分岐は値を渡さない。void、単一値型、s33型インデックスのblocktypeを区別する。
- モジュール内のtag定義に対応する。payloadは0個以上のi32、結果は空。
  同じシグネチャのtagも、別インスタンスのtagも、異なる識別値になる。
- `catch`、`catch_ref`、`catch_all`、`catch_all_ref`は宣言順に照合する。
  catchのdepth=0はtry_table自身ではなく、その外側の直近ラベルを指す。
- nullable exnrefをローカル、一時値、block結果として保持する。
  `local.get/set/tee/drop`と`throw_ref`に対応し、nullの再送出はtrapになる。

旧形式のtry/catch/rethrow/delegate、tag import/export、ホスト例外、間接call、
非i32 payload、block/loop引数、関数の複数結果、参照型の関数引数・結果、
非nullable参照宣言、ref.null、参照比較、typed selectは対象外。
未export関数や到達不能コードの未対応命令も拒否する。
共有ローダーはtag index、型index、catch種別、label depth、payload/label型、
新しいヘッダーのLEB128と入力切れを検査する。完全なWasm validatorではない。

## Ruby API

```ruby
instance = Wardite.new(path: "example.wasm", enable_wasi: false, engine: :efflorescence)
instance.runtime.call("catch_call", [])         # Wardite::I32(42)
instance.runtime.call_unboxed("catch_call", []) # 42
```

未捕捉のWasm例外は`Wardite::UncaughtWasmException`。
`error.tag`、`error.payload`、`error.exception_value`を検査できる。
payloadは送出時にコピーした不変配列で、フレーム解放後も値を保持する。
整数0除算、unreachable、nullのthrow_ref等のtrapはcatch_allを通らない。
start関数からの未捕捉Wasm例外も同じ専用エラーになる。
例外・trapの後も同一VMを再度呼び出せる。

## MIRと検証

整数bankは`Array[Integer]`を維持し、例外参照を別bankへ格納する。
共通の仮想レジスタ番号に`register_types`を対応させ、参照転送には`COPY_REF`を使う。
複数結果の転送は全sourceを同型の一時レジスタへ保存してからdestinationへ書く。
selectは条件分岐とcopy、br_tableは比較・条件分岐・各targetへの転送へ展開し、
flat命令の4整数幅を維持する。

`EH_ENTER`と`EH_TRIM`でFrame内handlerスタックの寿命を明示する。
通常end、領域外分岐、taken br_ifで必要なhandlerだけを解除し、loopのbackedgeでは維持する。
送出地点はFunctionのThrowSite、捕捉先はHandlerDescriptor/CatchTargetへ格納する。
伝播は明示的なFrame配列を巻き戻して行い、Wasm例外によるRubyのraise/rescueは使わない。
フレームを返却するときに参照bankとhandlerをクリアし、公開呼び出しのensureでも残ったFrameを解放する。

共通CFGはCALL/THROW/THROW_REFから候補catch先への例外edgeを持つ。
定義集合は送出直前の集合に、その節のpayload/ref定義だけを加える。
CALLの正常結果や後続命令の定義を例外edgeへ流さない。
通常edgeのhandler列が一致しないMIRも拒否する。
protected CALLで基本ブロックを区切り、handlerだけから到達するコードも検証する。

EH・参照を使う関数はcopy/immediate/branch/superinstructionとinliningの対象から除外する。
その関数へのinliningと、その関数内でのinliningの両方を停止する。
通常のi32関数には従来の最適化を維持し、div/remを未使用結果の除去対象にしない。
profilingのPC書き換えはdescriptorにも適用し、flat descriptorはsemantic descriptorからコピーして作る。
MIR dumpにはhandler/throw表も表示する。

## 再現する検証

```sh
bundle exec rake test
bundle exec rake check
make spinel-test RUBY="bundle exec ruby"
bundle exec ruby -Ilib benchmark/validate_m1_eh.rb
```

通常テストはwasm-toolsを使う。Spinelは別途native実行ファイルを生成して検証する。
EHの共通ケースはCRuby/Spinelそれぞれのdefault、all無効、flat無効、frames無効、profilingで実行する。
i32は各passの個別無効化も検査する。
通常命令は固定期待値と旧VMで比較し、EHは固定期待値とWasmtimeで比較する。
[最小受け入れ例](../test/fixtures/efflorescence/eh_acceptance.wat)の2つのexportは42を返す。

参照エンジンはWasmtime **49.0.0** (`17830bd3c`)、`-W exceptions=y`。
まず最小例の`rethrow`実行で新形式EHの動作を確認し、共通ケース全体を比較した。
入力のparse/validateはwasm-tools **1.218.0**。
仕様の確認先は[WebAssembly/specのEH explainer](https://github.com/WebAssembly/spec/blob/859d3232a55cdbb9d75343a072b05cd0a2172e1a/proposals/exception-handling/Exceptions.md)
（確認時main: `859d3232a55cdbb9d75343a072b05cd0a2172e1a`）。

性能計測と検証結果は以下に記録する。

## 性能記録（2026-11-05）
比較元は`0afa9d4`。macOS 27.0.1 / arm64、CRuby 4.0.9（YJITなし）、
Spinel 2026.10.25+1968 (`6f1a2c259`、ローカルのfetch root最適化を含む同一コンパイラ)を使用した。
Spinelは`--strict-require -O2`、整数overflow設定の変更なし。
各caseでwarmup 2回、測定7回、seed=123。測定順はbefore/afterを交互に反転する。
callを残すため`inline`のみ無効化し、flatとframesを有効にする。
ロードはバイナリ読み込み・変換・最適化・検証・loweringを含み、プロセス起動を含まない。
実行時間は1回の公開呼び出しで、FramePoolの生成も含む。
両revisionの全checksumを照合し、独立した算術期待値とも一致した。
再現手順（比較元を別ディレクトリへ展開し、同じworkerをそれぞれビルドする）:

```sh
spinel -I BEFORE/lib --strict-require -O2 BEFORE/benchmark/call_cost_worker.rb -o /tmp/m1-before
spinel -I lib --strict-require -O2 benchmark/call_cost_worker.rb -o /tmp/m1-after
RUNS=7 ROUNDS=1000000 bundle exec ruby benchmark/measure_m1.rb /tmp/m1-before /tmp/m1-after
```

CRubyはworkerコマンドを`ruby -I REVISION/lib REVISION/benchmark/call_cost_worker.rb "$@"`の
shell wrapperへ置き換え、`ROUNDS=100000`で同じ計測scriptを使う。

### Spinel（1,000,000 rounds）
時間の単位はms。実行はmedian (min–max)、ロードはmedian。
[全サンプル](../benchmark/results/efflorescence-m1-spinel.json)。
| case | 実行 before | 実行 after | ロード before | ロード after | checksum |
|---|---:|---:|---:|---:|---:|
| inline_mix | 20.493 (20.314–20.632) | 21.492 (21.405–21.654) | 0.193 | 0.238 | 1259766978 |
| call_mix | 41.905 (37.552–43.001) | 40.872 (39.666–40.987) | 0.198 | 0.245 | 1259766978 |
| empty_loop | 7.207 (7.114–7.336) | 7.464 (7.370–7.584) | 0.294 | 0.374 | 123 |
| call_zero | 28.429 (28.204–30.042) | 29.282 (29.102–34.397) | 0.315 | 0.412 | 7000123 |
| call_one | 24.606 (23.652–28.444) | 25.072 (24.531–26.492) | 0.303 | 0.389 | 123 |
| call_two | 32.306 (31.459–33.194) | 33.381 (32.780–34.210) | 0.312 | 0.402 | 1000123 |
| call_three | 38.364 (37.594–39.572) | 40.007 (38.349–40.641) | 0.301 | 0.391 | 3000123 |
| call_four | 43.723 (41.950–45.674) | 44.924 (43.922–46.411) | 0.295 | 0.378 | 6000123 |

### CRuby（100,000 rounds）
時間の単位はms。実行はmedian (min–max)、ロードはmedian。
[全サンプル](../benchmark/results/efflorescence-m1-cruby.json)。
| case | 実行 before | 実行 after | ロード before | ロード after | checksum |
|---|---:|---:|---:|---:|---:|
| inline_mix | 68.260 (62.319–69.219) | 67.896 (65.504–71.911) | 0.567 | 0.777 | 3870791521 |
| call_mix | 110.126 (108.529–115.335) | 114.704 (111.464–115.871) | 0.582 | 0.754 | 3870791521 |
| empty_loop | 20.725 (19.514–22.042) | 21.680 (19.783–22.367) | 1.077 | 1.446 | 123 |
| call_zero | 74.456 (72.527–77.215) | 76.117 (74.892–83.608) | 1.042 | 1.484 | 700123 |
| call_one | 64.075 (63.108–65.957) | 65.578 (64.503–66.601) | 1.039 | 1.414 | 123 |
| call_two | 81.473 (78.391–85.651) | 82.308 (80.610–85.755) | 1.019 | 1.420 | 100123 |
| call_three | 96.896 (95.647–101.779) | 99.317 (97.528–101.951) | 1.051 | 1.413 | 300123 |
| call_four | 112.399 (108.697–115.785) | 112.816 (110.752–115.538) | 1.046 | 1.454 | 600123 |

通常命令のMIR命令数・checksumは維持した。大きな退行の原因だったnullable PCの伝播を切り、
生成Cのflat dispatchが`sp_int lv_pc`を保つことを回帰テストにした。
参照/handler cleanupを必要なFrameだけで行い、通常passでの完全CFG構築の重複も除いた。
最終計測の実行median差は各caseで約-2.5%〜+5%の範囲。ロードは型情報・CFG・定義/型検証の
追加コストが残り、この小さいモジュールでは約0.05〜0.44ms増える。
EHなしのALU dispatchに参照型判定やhandler探索は加えていない。
EH専用の高速化はこの段階の目的に含めない。

## 最終検証結果

- `bundle exec rake test`: 165 tests / 12,921 assertions、失敗・エラーなし。
  native専用52テストはこのコマンドでは省略し、下のSpinel実行で検証した。
- `bundle exec rake check`: RBS生成後のSteep検査成功。
- `make spinel-test RUBY="bundle exec ruby"`: 52 tests / 2,670 assertions、失敗・エラー・省略なし。
  生成Cのswitch/PC/Frame配列の型、native CLIの構成別動作、同一VMの例外後再呼び出しを含む。
- `bundle exec ruby -Ilib benchmark/validate_m1_eh.rb`: 23呼び出しが固定期待値・Wasmtimeと一致。
- ベンチマークのbefore/after checksumは全サンプルで一致し、独立した算術期待値とも一致。
