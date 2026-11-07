# Efflorescence VM（Phase 1）

[English](efflorescence.md)

現在の対応範囲は [M1](efflorescence-m1.md)、[M2](efflorescence-m2.md)、[M3](efflorescence-m3.md) の実装記録を参照してください。
以下のPhase 1の制限は実装当時の記録です。

この文書はPhase 1（`67fbfae`）の記録です。現在のEfflorescenceでは、
[Phase 2の最適化](efflorescence-phase2-ja.md)がデフォルトで有効になります。
`--mir-disable all` で、最適化していないMIRをflatへ変換して実行します。
実行器はflatに統一され、flatを切り替える最適化フラグはありません。
Wardite全体のデフォルトは、引き続き既存のスタックVMです。

Efflorescenceは、明示的に選択して使う、Pure Ruby製のレジスタ型インタプリタです。
デフォルトは引き続き、スタック型インタプリタの `Wardite::Runtime` です。
両エンジンはバイナリローダー、デコード済みのWasm命令、ストア、エクスポート情報を共有しますが、
実行処理は独立しています。

```sh
wasm-tools parse benchmark/i32_mix.wat -o build/i32_mix.wasm
ruby -Ilib exe/wardite --new-engine --no-wasi --invoke inline_mix build/i32_mix.wasm 100000 123
ruby -Ilib exe/wardite --new-engine --no-wasi --invoke call_mix build/i32_mix.wasm 100000 123
# どちらも: return value: I32(-424175775)
```

Ruby APIで同じ処理を行う場合は、次のように呼び出します。

```ruby
require "wardite"
instance = Wardite.new(path: "build/i32_mix.wasm", enable_wasi: false, engine: :efflorescence)
instance.runtime.call("call_mix", [100000, 123]) # Runtimeと同じくWardite::I32を返す
instance.runtime.call_unboxed("call_mix", [100000, 123]) # 3870791521 (Integer)
```

Spinelでも同じソースコードを使います（`make spinel`）。
エクスポートされた関数は、`runtime.call` またはCLIから呼び出してください。
現在のSpinelは、未定義メソッドの呼び出しをRubyの `method_missing` に転送しません。
この制約は、既存VMが提供する簡便な呼び出しAPIにも当てはまります。
Spinel固有のランタイムAPIや、プログラム全体の整数オーバーフロー設定を変更するオプションは不要です。

## MIRと実行処理

新しく実装したクラスは、すべて `Wardite::Efflorescence` 名前空間にあります。

| クラス | 役割 |
| --- | --- |
| `IR` | モジュール内の変換済み関数を、Wasmの関数インデックスで参照できる形で保持する |
| `Function` | 関数インデックス、引数・戻り値の型、ローカル変数の数、レジスタ数、レジスタの初期値、命令列を保持する |
| `Instruction` / `Opcode` | 整数のオペランドと、整数のopcode定数を表現する |
| `Translator` / `Translator::Control` | 抽象オペランドスタック、構造化されたラベル、スナップショット、結果の合流、分岐先PCの解決を扱う |
| `Frame` | 関数、Integerのレジスタ配列、戻り値の格納先、保存したPCを保持する |
| `VM` | エクスポートの確認、Rubyとの境界での値変換、独立した命令ディスパッチ、明示的な呼び出しフレームの管理を行う |

`Instruction` は `Array<Integer>` を包む小さなクラスです。
Spinelが外側の命令テーブルを汎用配列として扱う場合でも、このクラスを介して
整数型のオペランドにアクセスできます。
命令オブジェクトは変換時に確保し、命令のディスパッチ中には確保しません。

| MIRの形式 | 意味 |
| --- | --- |
| `[COPY, dst, src]` | レジスタの値をコピーする |
| `[I32_ADD/SUB/MUL/XOR/SHL/SHR_U, dst, lhs, rhs]` | Wasmの二項演算を行う |
| `[I32_EQZ, dst, src]` | 値がゼロかどうかを判定する |
| `[BR, pc]`, `[BR_IF, condition, pc]` | MIR内の絶対PCへ分岐する |
| `[CALL, dst, function_index, *argument_registers]` | 内部関数を呼び出す（戻り値なしの場合は `dst = -1`） |
| `[RETURN, src]` | 関数から戻る（戻り値なしの場合は `src = -1`） |
| `[TRAP]` | Wasmの `unreachable` に対応する |

ローカル変数には、レジスタ配列の先頭からスロットを割り当てます。
`local.get` は、変換器の抽象スタックに値ソースを積むだけで、実行時の命令を生成しません。
抽象スタック上に値ソースとして残っているローカル変数を上書きする前に、
変換器はその旧値を一時レジスタにコピーし、対応する値ソースを差し替えます。
block/loopの入口では、分岐先となる位置よりも前で、まだ参照されるローカル変数の値ソースを
スナップショットとして保存します。これにより、通常の分岐やループ先頭への分岐をまたいでも、
ブロックに入る前からスタックに積まれていた値が保たれます。
`local.tee` も同じ仕組みを使います。
定数は同じ値を重複して保持せず、書き換えない初期値スロットに配置します。
`i32.const` も実行時の命令を生成しません。

各演算の結果には、一時スロットを割り当てます。
結果を持つblockや関数には合流用のスロットを設け、そこへ向かう分岐と通常の終了経路の両方から、
結果をそのスロットにコピーします。
loopへの分岐先は先頭で、引数は引き継ぎません。blockへの分岐先は末尾で、結果を引き継ぎます。
無条件に制御を移すと、その制御領域内の後続部分は到達不能になります。
実行時には、Wasmのラベルやオペランドスタックを保持しません。

レジスタには常に、符号なし32bitの範囲 `0..0xffffffff` に収まるRubyのIntegerを格納します。
加算・減算は32bitでラップアラウンドし、シフト量には下位5bitを使います。
乗算は16bitごとに分割して計算し、結果をマスクする前にSpinelのネイティブな符号付き整数が
オーバーフローすることを避けます。
内部関数の呼び出しでは、独立したフレーム間でIntegerのまま値をコピーします。
Rubyへ返す最終結果をboxingするのは `VM#call` だけで、`call_unboxed` はboxingしません。
呼び出しには明示的なフレーム配列を使うため、Wasm側の再帰はRubyのメソッド呼び出しスタックを消費しません。

このMIRを実行するために、最適化パスは必要ありません。
将来の最適化パスは、変換と実行の間で、Functionごとに適用できます。
Phase 1では、安全側に倒したCOPYや一時レジスタを意図的に残しています。

## 対応範囲と検証

対応しているのは、i32の引数・戻り値・ローカル変数・定数、get/set/tee、add/sub/mul/xor、
shl/shr_u/eqz、block/loop/br/br_if/end、call/return、nop/drop/unreachable、
および関数のエクスポートです。
blockとloopは、戻り値なし、またはi32の戻り値1個に対応しています。
loopの引数と、型インデックスを使ったブロックシグネチャには対応していません。

import・ホスト関数、WASI呼び出し、メモリ・グローバル変数・テーブルの命令、if/else、
その他の数値演算、複数の戻り値を持つシグネチャ、高度なWasmの提案機能では、
`UnsupportedFeature` を送出します。
定義されたすべての関数を事前に変換するため、到達不能なコードやエクスポートされていない関数にある
未対応命令も拒否します。
`Wardite::Runtime` へのフォールバックは行いません。
共有ローダーのバイナリデコードと検証に関する既存の制約は、そのまま適用されます。

```sh
bundle exec rake test
bundle exec rake check
make spinel-test RUBY="bundle exec ruby"
ruby benchmark/compare_engines.rb 100000 123
```

テストでは、既存の `wasm-tools parse` の手順を使い、
**変更を加えていない `benchmark/i32_mix.wat` 全体**をコンパイルします。
ビルド済みのテスト用バイナリや、処理量を減らしたプログラムへの置き換えは行いません。
指定された8組すべての入力について、CRubyとSpinel上で、両方のエクスポート関数・両方のエンジンの結果を、
剰余演算に基づく独立した参照実装と照合します。
追加のテストでは、スナップショット、結果を引き継ぐ分岐、ループに入る前からスタックにある値の保持、
再帰、戻り値のない呼び出し、値の正規化、シフト量、符号なし整数の乗算、未対応機能、CLIでのエンジン選択を確認します。
TracePointを使った回帰テストでは、内部関数を1,000回呼び出しても、I32の生成はRubyへ戻る境界での1回だけであり、
`Wardite::Runtime` のメソッドを一度も実行しないことを確認します。

2026年11月3日に、CRuby 4.0.9とSpinel `2026.10.25+1967`
（`6e7fc1355`、デフォルトの整数オーバーフローチェック）で検証しました。
`WARDITE_SPINEL_BIN` を有効にして全テストを実行した結果は、
**75テスト、1,106 assertions、失敗・エラー・省略はいずれも0件**でした。
`bundle exec rake check` も成功しています。
両方のエクスポート関数・両方のエンジン・両方のランタイムで、次の符号なし整数の結果が得られました。

| rounds | seed | checksum |
| ---: | ---: | ---: |
| 0 | 0 | 0 |
| 0 | 123 | 123 |
| 1 | 0 | 186080479 |
| 1 | 123 | 434058398 |
| 10 | 123 | 483678737 |
| 1000 | 123 | 1949289519 |
| 1000 | 4294967295 | 1895198137 |
| 100000 | 123 | 3870791521 |

[性能比較の記録](../benchmark/README.md#phase-1-sample-2026-11-03)。

次の段階では、独立した最適化パスによるCOPYと一時レジスタ数の削減、即値への特殊化、
Spinel向けの命令テーブル表現の改善、フレームの再利用、対応するWasm命令と制御構造の拡張を進めます。
性能向上そのものは、Phase 1の受け入れ条件には含めません。
