# Efflorescence M3 のホスト呼び出しと間接呼び出し

[ADR 0003](adr/0003-efflorescence-m3-host-and-indirect-calls.md) の実装記録。

M3 は i32 引数と、結果なしまたは単一 i32 結果の関数 import を扱う。
直接 `call` と table 0 の funcref を使う `call_indirect` は、モジュール内の defined 関数と imported 関数の両方を呼べる。
再エクスポートした import は `call` と `call_unboxed` から呼べる。ローダーは import、型、active element、MIR を準備してから start を実行する。

## ホスト ABI と例外

通常の `WasmModule#callable` または `HashModule` が解決した callable には、共有 Store と呼び出しごとに作る `Array[Wardite::I32]` を渡す。
ホストは void 関数で `nil` を返し、i32 関数で `Integer` または `Wardite::I32` を返す。
VM は i32 の戻り値を unsigned 32 bit に正規化し、公開 `call` は結果を `Wardite::I32` に戻す。
共有 Store への書き込みや memory.grow は復帰後の Wasm から読める。

```ruby
require "wardite"

# guest.wasm imports env.increment as (param i32) (result i32).
instance = Wardite.new(
  path: "guest.wasm",
  engine: :efflorescence,
  import_object: { env: { increment: ->(_store, args) { args.fetch(0).value + 1 } } }
)
```

各公開呼び出しはフレーム、プール、計測カウンターを所有する。再入の完了時に内側の `metrics` を確認でき、外側が終了すると外側の集計が公開される。
Wasm の間接呼び出し先が投げた Wasm 例外は、呼び出し元の handler に伝播する。
ホストの Ruby 例外と間接呼び出しの trap は Ruby の公開境界に伝播する。ホストが再入先の未捕捉 Wasm 例外を受け取った場合も同じ経路を通る。
公開呼び出しの終了時にフレームを解放し、完了済みの Store 更新は残る。

## CRuby の組み込み WASI

`Wardite::Efflorescence::WasiSnapshotPreview1` は既存の WASI 環境を継承して fd や argv、preopen を共有する。
専用経路の対象は `fd_write` と `proc_exit` の2関数。リンク時に組み込み WASI の実体と関数型を照合する。
VM は直接・間接・再エクスポートの呼び出しを同じ整数 ABI に接続する。通常のホストと他の既存 WASI 関数は boxed ABI を使う。

`fd_write` は現在の共有 memory 0 を参照し、iovec の各フィールドを little-endian で読む。
テーブル、バッファ、nwritten の範囲が無効な場合は `EFAULT` を返す。
複数の iovec は書き込み前に検査する。正常時は書き込んだバイト数を little-endian の u32 としてメモリに格納する。
`proc_exit` は整数の終了コードを Ruby の `exit` に渡す。

## MIR と計測

Wasm 関数 index は `FunctionEntry` で解決する。FramePool は defined 関数だけの dense index で引く。
`CALL_HOST` と `CALL_INDIRECT` は4整数幅の flat 命令で、引数レジスタと型を side table に保持する。
間接呼び出しは実行時の table から参照を取り、インスタンス化時の Store 関数と同一であることを確認してから、引数型列と結果型列を比較する。
dynamic call のある関数では、local pass と caller/callee 双方の inlining を止める。

`--mir-profile` の `host_calls` は ABI を通じて実行した callable の件数で、再エクスポートを含む。
`indirect_calls` は trap を含む間接命令の実行数、`function_entries` は実際の呼び出し先への進入数、`frames_created` は生成した内部フレーム数。
間接ホスト呼び出しは前二者にそれぞれ一件、`function_entries` に一件を加える。

## 検証

- CRuby で ABI、リンク失敗、再入、EH、table の更新、共有 Store を検証した。WASI は `fd_write` の stdout・errno・nwritten と、子プロセスでの `proc_exit` の終了コードを確認した。
- Spinel で `WasmModule` と `HashModule` を使い、通常のホスト関数、再エクスポート、間接呼び出し、型 trap、table の更新を検証した。
- Wasmtime 49.0.0 (`17830bd3c`) の `run -W exceptions=y --invoke run` と、別 type index の同一型、間接 throw の catch、型不一致・null・範囲外の trap を実行比較した。バイナリ生成には wasm-tools 1.218.0 を使用した。

```sh
bundle exec rake test
bundle exec rake check
make spinel-test RUBY="bundle exec ruby"
ruby -Ilib benchmark/validate_m3.rb
```

## 性能

CRuby 4.0.9（YJIT 無効）、Spinel `6f1a2c259`（`-O2`）、arm64 macOS。
100,000 rounds、seed 123、ウォームアップ2回・計測5回。profiling と inlining を無効にして直接内部 CALL を測った。
各サンプルを別プロセスで実行し、固定 checksum と照合した。
既存 workload のロード時間はデコード・共有 Store 準備と MIR 構築の合計。

```sh
BASELINE_REF=44c85c1 MIX_ONLY=1 RUNTIMES=Spinel,CRuby RUNS=5 WARMUPS=2 ruby benchmark/compare_call_types.rb 100000
BASELINE_REF=44c85c1 CALL_ARITIES=1 RUNTIMES=Spinel,CRuby RUNS=5 WARMUPS=2 ruby benchmark/compare_call_types.rb 100000
RUNS=5 WARMUPS=2 ROUNDS=100000 ruby benchmark/measure_m3_calls.rb
```

### 既存 workload

実装前は `44c85c1`。表は各フェーズの中央値（ms）。

| case | checksum | CRuby ロード 前 → 後 | CRuby 実行 前 → 後 | Spinel ロード 前 → 後 | Spinel 実行 前 → 後 |
|---|---:|---:|---:|---:|---:|
| `inline_mix` | 3870791521 | 2.123 → 1.466 | 90.751 → 92.697 | 0.406 → 0.398 | 3.078 → 3.087 |
| `call_mix` | 3870791521 | 2.271 → 1.364 | 159.970 → 161.815 | 0.419 → 0.438 | 5.566 → 5.841 |
| `empty_loop` | 123 | 3.124 → 2.403 | 28.454 → 29.120 | 0.648 → 0.656 | 1.080 → 1.082 |
| `call_zero` | 700123 | 2.417 → 3.162 | 108.711 → 110.656 | 0.631 → 0.667 | 4.317 → 4.315 |
| `call_one` | 123 | 2.341 → 2.479 | 93.809 → 94.909 | 0.635 → 0.643 | 3.767 → 3.683 |
| `call_two` | 100123 | 2.381 → 2.572 | 119.524 → 121.194 | 0.638 → 0.643 | 4.780 → 4.787 |
| `call_three` | 300123 | 2.374 → 2.777 | 143.045 → 144.242 | 0.636 → 0.642 | 5.706 → 5.600 |
| `call_four` | 600123 | 2.338 → 3.293 | 159.685 → 161.065 | 0.631 → 0.654 | 6.473 → 6.362 |

初回比較で Spinel の `call_mix` と一部の多引数 CALL が遅くなった。
動的呼び出しの処理を flat ループの外へ分離し、RETURN の i32 値を生成 C で整数として扱うようにした。
100万 rounds の交互計測では、`call_three` の中央値が baseline 56.450 ms、初回59.241 ms、修正後56.468 ms だった。
表の `call_mix` では 5.566 → 5.841 ms（+4.9%）の差が残った。

### M3 の4つの呼び出し経路

各経路は1引数に1を加える処理を同じ回数だけ反復する。checksum は全経路で 100123。
ホスト経路の実行時間には引数の boxing と Ruby callable の実行を含む。

| runtime | case | ロード中央値 (ms) | 実行中央値 (min–max, ms) |
|---|---|---:|---:|
| CRuby | `direct_defined` | 2.007 | 108.269 (106.670–113.130) |
| CRuby | `direct_host` | 2.056 | 131.376 (130.582–134.535) |
| CRuby | `indirect_defined` | 2.188 | 217.520 (216.736–219.541) |
| CRuby | `indirect_host` | 2.087 | 197.252 (196.326–227.577) |
| Spinel | `direct_defined` | 0.437 | 4.045 (4.035–4.075) |
| Spinel | `direct_host` | 0.418 | 12.571 (12.407–12.661) |
| Spinel | `indirect_defined` | 0.428 | 13.308 (13.272–13.507) |
| Spinel | `indirect_host` | 0.429 | 19.676 (19.592–19.903) |

### 組み込み `fd_write` の専用化

同じ Efflorescence VM に、従来の `Wardite::WasiSnapshotPreview1` を明示登録した場合と、組み込みの専用経路を選んだ場合を比較した。
CRuby 4.0.9（YJIT 無効）、arm64 macOS で、4 byte の iovec を `IO::NULL` へ同期書き込みする処理を100,000回実行した。
各経路を2回ウォームアップして5回計測し、全回で errno 0 と合計400,000 byte を確認した。

| 経路 | 実行中央値 (min–max, ms) | Ruby 割り当て数の中央値 |
|---|---:|---:|
| 既存 boxed WASI | 594.074 (590.461–602.586) | 1,900,013 |
| 専用 i32 WASI | 456.381 (451.621–465.679) | 300,013 |

実行時間は23.2%短縮、割り当て数は84.2%減少した。計測には VM のループと同期 I/O も含み、差には ABI と iovec の読み取り処理の両方が寄与する。

```sh
ruby --disable-yjit -Ilib benchmark/measure_wasi_write.rb
```
