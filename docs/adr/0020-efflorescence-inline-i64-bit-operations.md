# ADR 0020: i64のビット演算・シフト・比較をexecute_flatで直接計算する

- **状態** 提案
- **日付** 2026-11-17
- **基準** Wardite 1.2.2 `5baaf38`、Spinel `58ee636`（CIの `SPINEL_REF`）、`-O2`、既定の整数overflow検査
- **関連** [ADR 0004](0004-efflorescence-m4-i64.md)（i64の表現）、[ADR 0018](0018-efflorescence-real-workload-measurement.md)（計測の基準）

## 決定

`VM#execute_flat` で、次のi64命令を `I64Arithmetic.calculate` を呼ばずに直接計算する。

- ビット演算：`I64_AND`、`I64_OR`、`I64_XOR`
- シフトと回転：`I64_SHL`、`I64_SHR_S`、`I64_SHR_U`、`I64_ROTL`、`I64_ROTR`
- 比較：`I64_EQZ`、`I64_EQ`、`I64_NE`、符号付きと符号なしの `LT`・`GT`・`LE`・`GE`
- 変換：`I32_WRAP_I64`、`I64_EXTEND_I32_U`、`I64_EXTEND_I32_S`、`I64_EXTEND8_S`、`I64_EXTEND16_S`、`I64_EXTEND32_S`

i64の表現は変えない。計算の途中の値も符号付き64ビットの範囲に収め、Spinelの既定の整数overflow検査に掛からない式だけを使う。`I64_ADD`・`I64_SUB`・`I64_MUL`・除算・剰余と、`I64_CLZ`・`I64_CTZ`・`I64_POPCNT` は、今と同じく `I64Arithmetic.calculate` で計算する。

## 背景

### Base64ではi64の命令が実行命令の3〜4割を占める

Rustのbase64 crateは、入力を `u64` 単位でまとめて処理する。wardite-benchesの `base64_codec` で実行したMIR命令を数えると、i64の命令が多い。数え方は [ADR 0021](0021-efflorescence-optimize-real-functions.md) と同じで、実行回数の上位30命令に入ったi64の命令を挙げた。割合は全命令に対する値である。

| 命令 | encode | decode |
|---|---:|---:|
| `I64_SHR_U` | 8.2% | 4.4% |
| `I64_OR` | 5.7% | 9.7% |
| `I32_WRAP_I64` | 5.7% | — |
| `I64_AND` | 4.9% | 4.4% |
| `I64_SHL` | 3.3% | 8.9% |
| `I64_EQ`・`I64_NE` | — | 7.1% |
| `I64_LOAD8_U` などのload・store | 0.8% | 8.9% |
| 合計 | 28.6% | 43.4% |

この決定の対象になるのは、表のうちload・storeを除いた命令で、encodeの27.8%、decodeの34.5%にあたる。

### i64の命令は毎回、関数の外の汎用ルーチンを呼ぶ

`execute_flat` のi64命令は、すべて `I64Arithmetic.calculate(opcode, left, right)` を呼ぶ（[vm.rb](../../lib/wardite/efflorescence/vm.rb#L967)）。`calculate` は、opcodeで再び `case` を引く（[i64_arithmetic.rb](../../lib/wardite/efflorescence/i64_arithmetic.rb#L211)）。シフトは、32ビットずつの半分に分けて `low`・`high`・`join` で組み立てる。符号なし比較も `low` と `high` を取り出して比べる。

32 MiBの入力でSpinel `58ee636` のビルドを動かし、macOSの `sample` で1 ms間隔のプロファイルを取った。`I64Arithmetic.calculate` と、そこから呼ぶシフトの補助メソッドに、encodeでCPUサンプルの32%、decodeで36%があった。

`AND`・`OR`・`XOR` と符号付きの比較は、符号付き64ビットの値のまま計算でき、今も `calculate` の中ではそうしている。シフトと符号なし比較も、下の式でoverflowせずに計算できる。

## 式

i64のレジスタは、Wasmのビット列を2の補数として読んだ符号付き64ビットの整数を持つ（[ADR 0004](0004-efflorescence-m4-i64.md)）。`MAX` は `2**63 - 1`、`MIN` は `-2**63` とする。シフト量 `n` は、Wasmの仕様どおり `right & 63` である。

| 命令 | 式 |
|---|---|
| `I64_SHR_S` | `v >> n` |
| `I64_SHR_U` | `n == 0 ? v : (v >> n) & (MAX >> (n - 1))` |
| `I64_SHL` | `n == 0 ? v : ((v & (MAX >> n)) << n) \| (((v >> (63 - n)) & 1) == 0 ? 0 : MIN)` |
| `I64_ROTL` | `SHL(v, n) \| SHR_U(v, (64 - n) & 63)`。`n == 0` のときは `v` |
| `I64_ROTR` | `I64_ROTL` を `(64 - n) & 63` で計算する |
| 符号なしの比較 | 両辺の符号ビットを `^ MIN` で反転し、符号付きで比べる。例：`LTU` は `(l ^ MIN) < (r ^ MIN)` |
| `I32_WRAP_I64` | `v & 0xffffffff` |
| `I64_EXTEND_I32_U` | `v`。i32のレジスタは `0..0xffffffff` を持つ |
| `I64_EXTEND_I32_S`・`I64_EXTEND32_S` | `((v & 0xffffffff) ^ 0x80000000) - 0x80000000` |
| `I64_EXTEND16_S` | `((v & 0xffff) ^ 0x8000) - 0x8000` |
| `I64_EXTEND8_S` | `((v & 0xff) ^ 0x80) - 0x80` |

`I64_SHL` は、`v` の下位 `63 - n` ビットだけを残してから左シフトする。結果は `2**63` 未満に収まる。`v` のビット `63 - n` は結果の符号ビットになるので、立っていれば `MIN` との論理和で付け加える。`I64_SHR_U` は、算術シフトで入った上位 `n` ビットをマスクで消す。マスク `MAX >> (n - 1)` は `n >= 1` で `2**(64 - n) - 1` になる。

`I64_SHL`・`I64_SHR_S`・`I64_SHR_U` と `I64_LTU` の式は、既存の `I64Arithmetic.calculate` と一致することを確かめた。境界の値10個と疑似乱数の値3,000個に、0〜63の全シフト量を組み合わせた。CRuby 4.0.9と、Spinelの既定のoverflow検査でビルドしたネイティブバイナリの両方で、不一致とoverflowの例外は0件だった。

## 実装の方針

- 式は `execute_flat` の各 `when` に書くか、`I64Arithmetic` の小さなメソッドにして呼ぶ。どちらにするかは生成Cで決める。正常経路に `I64Arithmetic.calculate` の呼び出しと、nilを許す整数の検査が残らない形を選ぶ。
- `I64Arithmetic.calculate` は残す。対象外の命令と、ホストとの境界の変換は今の経路のままにする。
- MIRの命令、bytecode、MIR2キャッシュのフォーマットは変えない。命令の意味も変えないので、`MIRCache::CODE_VERSION` は上げない。

## 守る契約

- すべての入力で、結果のビット列を今と同じにする。i64のレジスタは常に `-2**63..2**63-1` の範囲を持つ。i32のレジスタは常に `0..0xffffffff` の範囲を持つ。
- 対象の命令はtrapしない。trapする命令の扱いは変えない。
- Spinelの整数overflowの設定を変えない。`--int-overflow=wrap` などに依存しない。

## 検証

- 対象の各命令について、`I64Arithmetic.calculate` との一致を単体テストで確かめる。値は `0`、`±1`、`MIN`、`MAX`、`MIN + 1`、`MAX - 1`、`±2**31`、`2**32 - 1` を含め、シフトと回転は0〜63の全シフト量と、64以上のシフト量を使う。CRubyと、Spinelのテスト（[test/spinel/efflorescence_m4.rb](../../test/spinel/efflorescence_m4.rb)）の両方で実行する。
- 既存の [efflorescence_m4_test.rb](../../test/efflorescence_m4_test.rb) と `bundle exec rake parity` を通す。
- wardite-benchesの `splitmix64`、`monte_carlo_pi`、`base64_codec`、`png_grayscale` の結果がWasmtimeと一致することを確かめる。
- `bundle exec rake test`、`bundle exec rake check`、`make spinel-test RUBY="bundle exec ruby"` を実行する。

## 計測と受け入れ条件

[ADR 0018](0018-efflorescence-real-workload-measurement.md) の手順と条件に従う。一次指標は、`base64_codec` の16倍の入力（encode・decode）でのプロセス全体の時間である。命令の数は変わらないので、MIR命令数の比較は使わない。i32だけのベンチと浮動小数点のベンチで回帰がないことも確かめる。
