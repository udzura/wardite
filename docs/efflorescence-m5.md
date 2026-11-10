# Efflorescence M5 の浮動小数点対応

[ADR 0005](adr/0005-efflorescence-m5-floating-point.md) の実装記録。

## 丸め方式

binary32 の演算には binary64 の中間値を使い、各命令の出口で binary32 に丸める。加減算では指数差が25以下なら中間の有効桁は50 bit以内に収まる。指数差がそれより大きければ、小さい項は大きい項から最も近い binary32 の丸め境界まで届かない。積の有効桁は48 bit以内に収まる。

除算の正規化した商は高々24 bitの分母を持つ有理数に2の累乗を掛けた形になる。商を [1, 2) にスケールすると、binary32 の中点と一致しない場合の距離は 2⁻⁴⁸ より大きい。平方根では同じスケールの中点を二乗し、radicand との差を取る。差がゼロでなければ絶対値は 2⁻⁴⁸ 以上で、根と中点との距離は 2⁻⁵⁰ より大きい。このため binary64 で丸めても binary32 の中点を越えたり、新たな tie が生じたりしない。subnormal の中点の間隔はさらに広く、ゼロとの境界は2の累乗なので同じ判定を適用できる。整数から float への変換にはこの議論を適用せず、整数の有効桁から丸める。

binary64 の四則と平方根はホストの binary64 演算を使う。平方根は符号付きゼロを先に返す。CRuby の `Math.sqrt(-0.0)` が正のゼロを返すためである。CRuby 4.0.9 と Spinel の `-O2` で、固定の bit fixture により両精度の bit 往復、binary32 の subnormal 付近の除算の tie とその上下、平方根の中点付近、binary64 の除算・平方根・subnormal、±0、NaN、infinity を確認する。

演算結果の丸め、特殊値、NaN の根拠は WebAssembly 3.0 の [Numerics](https://webassembly.github.io/spec/core/exec/numerics.html)。

## 対応した76命令と値の経路

| 命令 | 数 | 実行経路 |
|---|---:|---|
| `f32.const`、`f64.const` | 2 | 共有デコーダーの `FloatImmediate` から型別に重複排除し、フレームの整数レジスタへ配置 |
| `f32.load/store`、`f64.load/store` | 4 | M2 の全範囲検査を通して4または8 byteの little-endian bit列を転送 |
| 各精度の `eq/ne/lt/gt/le/ge` | 12 | `FloatArithmetic` で比較し、i32を生成 |
| 各精度の `abs/neg/copysign` | 6 | 符号ビット操作。NaN payloadを保持 |
| 各精度の `ceil/floor/trunc/nearest/sqrt` | 10 | 特殊値を先に処理し、nearestは ties-to-even |
| 各精度の `add/sub/mul/div/min/max` | 12 | 演算ごとに結果精度へ丸め、min/maxで符号付きゼロを選択 |
| `i32/i64.trunc_f32/f64_s/u` と対応する `trunc_sat` | 16 | 符号・指数・仮数から切り捨て後の整数を検査。通常版はtrap、satは飽和 |
| `f32/f64.convert_i32/i64_s/u` | 8 | unsigned magnitudeから目的精度へ直接丸め |
| `f32.demote_f64`、`f64.promote_f32` | 2 | 目的精度への丸めと正確な拡張 |
| `f32↔i32`、`f64↔i64` の `reinterpret` | 4 | 同幅のbit列をそのまま転送 |

`f32` は unsigned 32 bit、`f64` は signed 64 bitのcarrierで保持する。local、COPY、select、ブロック合流、定義関数への直接・間接呼び出しとフレーム再利用でFloatへ変換しない。globalでは共有Storeが値を所有し、Float wrapperの `value=` はraw表現を破棄して更新する。EHの `payload_bits` はcatchとthrow_refで保持し、未捕捉時の公開 `payload` でだけfloatをデコードする。

`call_unboxed` のf32/f64結果はRuby Float、`call` は対応するwrapperを返す。float引数はFloatまたは対応wrapperを受理し、通常hostにはシグネチャ順にI32/I64/F32/F64を渡す。通常hostのfloat結果もFloatまたは対応wrapperを受理する。Ruby Floatを経由する公開境界でNaN payloadの完全保持は保証しない。i32専用のWASI経路は既存のsignature検査を通る。

`uses_float` の関数はlocal passとcaller/callee双方のinliningから除外する。MIRの型・定義検証、flat lowering、フレーム再利用、profilingは有効。定数はMIR dumpに型と16進bit列を出力する。

## 検証

```sh
bundle exec rake test
bundle exec rake check
make spinel-test RUBY="bundle exec ruby"
bundle exec ruby -Ilib benchmark/validate_m5.rb
```

CRuby 4.0.9で240件、26,069 assertions。Spinel専用70件はこのコマンドでは省略され、Spinel 6f1a2c259の `-O2` ビルドで70件、2,504 assertionsを省略なしで別実行した。既定、all無効、frames無効とprofilingを組み合わせて検証した。共有デコーダーのセクション長はバイト単位で照合する。SpinelのStringIOからの読み出しにUTF-8の文字として解釈できるbit列があると、従来の文字数比較は正常なWasmも拒否していた。

Wasmtime 49.0.0（`17830bd3c`）と wasm-tools 1.218.0で、70のALU・変換命令について固定381件とseed `0x20261110` の560件を比較した。float結果はWasm内でreinterpretして比較し、演算NaNは許容集合、符号操作とreinterpretは完全一致で判定した。raw global初期値と混在EHも一致した。

## 性能

Apple M3 Pro、arm64 macOS。CRuby 4.0.9（YJIT無効）、Spinel `6f1a2c259`（`-O2`、既定overflowチェック）。M4の比較基準は `e992d2c`。i32は100,000 rounds、i64/floatは20,000 rounds。別プロセスで実行順を交替し、2回のウォームアップ後の5回の中央値を比較した。ロードはStore準備とMIR変換・検証・loweringを含む。実行はprofilingとinliningを無効にして計測した。

```sh
baseline=$(mktemp -d)
git archive e992d2c | tar -x -C "$baseline"
RUNS=5 ruby --disable-yjit -Ilib benchmark/measure_m4.rb "$baseline" M4
ROUNDS=30000 RUNS=7 ruby --disable-yjit -I"$baseline/lib" benchmark/measure_wasi_write.rb
ROUNDS=30000 RUNS=7 ruby --disable-yjit -Ilib benchmark/measure_wasi_write.rb
wasm-tools parse benchmark/float_m5.wat -o build/float_m5.wasm
ruby --disable-yjit -Ilib benchmark/measure_m5_boundary.rb build/float_m5.wasm
spinel --strict-require -O2 -Ilib benchmark/measure_m5_boundary.rb -o build/float-boundary
build/float-boundary build/float_m5.wasm
```

| ケース | CRuby ロード ms | CRuby 実行 ms | Spinel ロード ms | Spinel 実行 ms |
|---|---:|---:|---:|---:|
| i32 `inline_mix` | 1.985 → 1.981 | 95.337 → 98.680 | 0.455 → 0.471 | 3.060 → 3.073 |
| i32 `call_mix` | 1.986 → 1.983 | 162.769 → 161.817 | 0.464 → 0.477 | 5.768 → 5.665 |
| i32 `direct_host` | 1.826 → 1.821 | 129.533 → 131.280 | 0.482 → 0.491 | 9.732 → 9.776 |
| i32 `indirect_host` | 1.827 → 1.844 | 195.234 → 193.030 | 0.469 → 0.485 | 17.293 → 17.827 |
| i64 `division` | 1.819 → 1.842 | 326.772 → 324.938 | 0.476 → 0.513 | 3.993 → 3.957 |
| i64 `memory` | 1.813 → 1.820 | 58.951 → 58.885 | 0.492 → 0.522 | 3.663 → 3.665 |
| i64 `mixed_call` | 1.821 → 1.822 | 63.373 → 63.692 | 0.478 → 0.518 | 2.171 → 2.206 |
| `float_alu` | 1.672 | 59.728 | 0.446 | 14.657 |
| `float_convert` | 1.677 | 84.460 | 0.454 | 8.452 |
| `float_mixed_call` | 1.684 | 74.434 | 0.449 | 14.124 |

Spinelの整数ロードに数十µsの増加がある。ロードには数値4型のシグネチャ検査と、型付きMIR命令表の検査が含まれる。Spinelのi32 `indirect_host` は3.1%増加し、同じ計測の `direct_host` の差は0.5%だった。i32専用hostはリンク時のABIフラグを使い、実行時に引数ごとの型分岐を行わない。M6で再計測する。

CRubyの `fd_write` は30,000回、計120,000 byte。専用ABIの実行中央値は133.267 → 132.934 msで、割り当ては90,014件。boxed ABIは177.469 → 176.553 ms。floatの境界計測では、f32 identityを30,000回呼んだ中央値がCRubyで96.557 ms（unboxed）と101.288 ms（boxed）、Spinelで25.549 msと27.440 msだった。boxed計測はwrapperをRuby Floatとして読む費用も含む。内部CALLの計測はループ内の引数・戻り値を整数carrierで転送する。

M5の実装基準は `e75dae1`。関数multi-value、block引数、typed select、SIMD、GC、tag import/export、host例外のWasm EH化はADRの対象外。
