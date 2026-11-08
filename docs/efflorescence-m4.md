# Efflorescence M4 の i64 対応

[ADR 0004](adr/0004-efflorescence-m4-i64.md) の実装記録。M4 は i64 命令と整数間変換の計47命令を追加した。関数引数、単一結果、local、untyped `select`、複数結果ブロック、global、例外ペイロードで i32 と i64 を混在できる。直接呼び出しと table 0 の間接呼び出しは、defined 関数と import の双方に対応する。

## 値と公開 API

フレームの数値レジスタは `Array[Integer]`。i32 は unsigned 32 bit、i64 は signed 64 bit で保持する。上位ビットの立った i64 も signed の範囲で演算する。加減算には32 bitの limb、乗算には16 bitの桁、除算には64ステップの long division を使う。除算は0方向に丸め、ゼロ除算と `MIN / -1` の signed division は trap になる。

`call` は結果型に応じて `Wardite::I32` または `Wardite::I64` を返す。`call_unboxed` は i32 の unsigned 値と i64 の signed 値を返す。void はどちらも `nil`。i64 の公開引数には `Integer` または `Wardite::I64` を渡せる。CRuby の任意精度整数も下位64 bitに正規化する。

```ruby
# "identity" has the signature (param i64) (result i64).
vm.call_unboxed("identity", [Wardite::I64(0xffff_ffff_ffff_ffff)]) # => -1
vm.call("identity", [-1]).value # => 18446744073709551615
```

通常のホストには引数型の順序で `I32` / `I64` を渡す。i64 結果には `Integer` と `I64` を受け付け、結果の型エラーは1回の呼び出しで確定する。例外の `UncaughtWasmException#payload` はタグ順の整数列で、i32 は unsigned、i64 は signed。数値 trap とホストの Ruby 例外は Ruby の境界に伝播する。

## MIR、Store、WASI

`uses_i64` を持つ関数は local pass と caller/callee 双方の inlining の対象から外す。MIR 検証、flat lowering、フレーム再利用、profiling は適用する。到達不能なコードでも命令の即値と具体的なスタック型を検証する。共有デコーダーでは `br_table` と `try_table` のベクターを専用の `OperandVector` で表し、Spinel の混在オペランド配列でも型を保持する。

i64 の load/store は1、2、4、8 byte の little-endian アクセス。ストアは全範囲を検査してから書き込む。global の保持元は共有 Store で、i64 の値はその境界でだけ変換する。catch と throw_ref はフレーム解放前に保存したペイロードを引き継ぐ。

CRuby では組み込み WASI の `path_open` を検証した。dirfd 3、フラグ0、6 byte の相対パス、i64 の `fs_rights_base = 2`（読み取り）と `fs_rights_inheriting = 0xffffffffffffffff` を渡した。既存実装は inheriting rights を読み取り、base rights を open flags に反映する。成功時は errno 0 と offset 32 に fd 4 を得て、ホスト側で一時ファイルの内容を読み取れた。存在しないパスでは `ENOENT` を返し、fd 出力欄を保持した。`fd_write` と `proc_exit` は従来の i32 専用経路を通る。Spinel では通常の `WasmModule` と `HashModule` を使って混在 ABI を確認した。

## 検証

```sh
bundle exec rake test
bundle exec rake check
make spinel-test RUBY="bundle exec ruby"
bundle exec ruby -Ilib benchmark/validate_m4.rb
```

CRuby の任意精度整数から境界値と固定シードの参照値を生成し、同じ入力・期待値を Spinel の既定 overflow チェックでも実行した。Wasmtime 49.0.0（`17830bd3c`、`-W exceptions=y`）と wasm-tools 1.218.0 で、35の ALU・変換 export、混在制御、メモリ、EH、間接呼び出しの計129ケースを比較した。旧 stack VM との比較には i32 引数から i64 を内部で渡す Wasm ラッパーを使った。

## 性能

Apple M3 Pro、arm64 macOS、CRuby 4.0.9（YJIT 無効）、Spinel `6f1a2c259`（`-O2`、既定 overflow チェック）。比較基準は M3 の main `17200af`。別プロセスで M3 と M4 の順序を交替させ、各ケースを2回ウォームアップして9回計測した。seed は123。ロード時間はデコード、Store 準備、MIR の変換・検証・lowering の合計。実行時間は profiling と inlining を無効にして測った。

```sh
baseline=$(mktemp -d)
git archive 17200af | tar -x -C "$baseline"
RUNS=9 ruby -Ilib benchmark/measure_m4.rb "$baseline"
ROUNDS=30000 RUNS=9 ruby --disable-yjit -I"$baseline/lib" benchmark/measure_wasi_write.rb
ROUNDS=30000 RUNS=9 ruby --disable-yjit -Ilib benchmark/measure_wasi_write.rb
```

### i32 の回帰計測

100,000 rounds の中央値（ms）。各セルは M3 → M4。4種類の呼び出しの checksum はすべて100123。

| case | checksum | CRuby ロード | CRuby 実行 | Spinel ロード | Spinel 実行 |
|---|---:|---:|---:|---:|---:|
| `inline_mix` | 3870791521 | 1.358 → 1.375 | 66.788 → 66.369 | 0.279 → 0.298 | 2.113 → 2.062 |
| `call_mix` | 3870791521 | 1.361 → 1.375 | 114.124 → 111.865 | 0.280 → 0.302 | 3.985 → 4.022 |
| `empty_loop` | 123 | 2.132 → 2.179 | 20.827 → 20.845 | 0.410 → 0.449 | 0.725 → 0.721 |
| `call_zero` | 700123 | 2.111 → 2.164 | 77.228 → 77.589 | 0.411 → 0.439 | 2.869 → 2.833 |
| `call_one` | 123 | 2.129 → 2.166 | 65.790 → 65.730 | 0.408 → 0.437 | 2.439 → 2.486 |
| `call_two` | 100123 | 2.112 → 2.161 | 83.336 → 83.235 | 0.414 → 0.457 | 3.278 → 3.205 |
| `call_three` | 300123 | 2.123 → 2.163 | 101.301 → 99.485 | 0.416 → 0.442 | 3.841 → 3.776 |
| `call_four` | 600123 | 2.123 → 2.167 | 114.753 → 114.347 | 0.416 → 0.440 | 4.398 → 4.367 |
| `direct_defined` | 100123 | 1.250 → 1.274 | 75.087 → 75.417 | 0.281 → 0.307 | 2.769 → 2.747 |
| `direct_host` | 100123 | 1.262 → 1.289 | 90.589 → 91.174 | 0.282 → 0.309 | 6.511 → 6.734 |
| `indirect_defined` | 100123 | 1.264 → 1.272 | 152.504 → 152.654 | 0.298 → 0.305 | 9.249 → 9.441 |
| `indirect_host` | 100123 | 1.249 → 1.270 | 133.428 → 135.577 | 0.284 → 0.309 | 11.591 → 11.974 |

初回計測では i32 のロードにも i64 opcode の型表参照と二段の定数検索が入り、Spinel の `call_mix` で 0.283 → 0.335 ms だった。i64 の照合を既存 opcode の分岐の外へ移し、定数の検索を型ごとのテーブルに分けた。再計測ではロードに数十 µs の差が残る。ロードには追加した直接呼び出しのシグネチャ検証と到達不能コードの検証も含まれる。

Spinel の `call_mix` 実行時間の差は約1%で、計測範囲は重なった。M3 内で存在した定義関数とホスト・間接呼び出しの差は表の M3 列で確認できる。M4 では、Spinel の直接・間接ホスト呼び出しで約3.3〜3.4%の増加を観測した。通常ホストの ABI 選択には、リンク時に記録した i64 フラグの判定が1回加わる。

CRuby の組み込み `fd_write` は 4 byte を `IO::NULL` へ30,000回書き込み、各回の errno 0 と合計120,000 byte を確認した。専用経路の実行中央値は 91.911 → 92.600 ms、割り当て数は90,013 → 90,014。比較用の boxed 経路は120.710 → 123.558 ms。`proc_exit` の終了コードと同名の通常ホストの ABI は e2e テストで確認した。

### i64 の計測

20,000 rounds の中央値（ms）。checksum は Wasmtime と照合した。

| case | checksum | CRuby ロード | CRuby 実行 | Spinel ロード | Spinel 実行 |
|---|---:|---:|---:|---:|---:|
| `alu` | 3171840554768500685 | 1.288 | 54.095 | 0.313 | 1.076 |
| `division` | 2305843009213693951 | 1.276 | 224.727 | 0.319 | 2.722 |
| `memory` | 85899345940123 | 1.278 | 40.775 | 0.316 | 2.507 |
| `mixed_call` | 200010123 | 1.274 | 43.926 | 0.309 | 1.491 |

時間計測から分けた CRuby の TracePoint では、全ケースで `call_unboxed` 中の `I64#initialize` が0回、`call` では戻り値の1回だった。ウォームアップ後の Ruby オブジェクト割り当ては順に320,654、19、19、23件。ALU ケースは CRuby が即値表現の範囲を越える整数をオブジェクトとして保持するため、割り当てが多い。Spinel のフレームは C の整数配列で、演算と内部 CALL で `I64` を生成しない。

profiling では `mixed_call` の20,001回の関数進入に対してフレーム生成は2回。ALU、除算、メモリの dispatch 数はそれぞれ220,006、160,006、180,006で、各ケースは1フレームを使った。
