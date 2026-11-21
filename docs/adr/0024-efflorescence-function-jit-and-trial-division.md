# ADR 0024: Spinel版に関数単位のMIR JITを導入し、i32の試し割りを実行する

- **状態** 採用・実装済み（完了）。[PR #72（JIT導入）](https://github.com/udzura/wardite/pull/72)、[PR #73（試し割り）](https://github.com/udzura/wardite/pull/73)
- **日付** 2026-11-21（実装後に記録）
- **確認時のmain** `25afb99`
- **関連** [ADR 0022（関数のMIR準備）](0022-efflorescence-lazy-function-build.md)、[ADR 0025（数値型と篩法）](0025-efflorescence-jit-numeric-types-and-sieve.md)

## 背景

整数ループでは、同じMIR命令の取得と分岐を反復ごとに繰り返す。既存の関数MIRからAArch64コードを生成し、ループへの出入りを含めて1回のネイティブ呼び出しで実行する。最初の対象はビット演算ループの `inline_mix` と、奇数の候補を試し割りして素数の個数を返す `count_primes` とした。

## 決定

Apple Silicon macOSのSpinel版で `WARDITE_MIR_JIT=1` を指定したとき、VMの公開呼び出し・start関数の入口で、準備済みのMIRを関数単位でコンパイルする。JITは既定で無効とする。プロファイル時はインタープリタで命令を数える。[VMの入口](../../lib/wardite/efflorescence/vm.rb)

引数は `i32` 1個または2個、結果は `i32` 1個とする。試し割りでは余りを `i32.rem_u` で求める。終了判定の「除数の二乗が候補を超えたか」は32ビットを超え得るため、ローカルでは `i64.extend_i32_u`、`i64.mul`、符号なし64ビット比較も扱う。先頭15スロットをレジスタに置き、残りをスタックに置く。[AArch64コード生成](../../lib/wardite/efflorescence/spinel_jit/aarch64.rb)

コンパイルできない関数はVMで実行する。生成コードがゼロ除算やtrap経路（panic用の直接呼び出しの直後にtrapがある場合を含む）に達したら、元の引数からVMで再実行する。この方式が成り立つのは、それまでのネイティブ実行がローカルな値だけを更新するためである。終了ステータスとWasmの結果は別々に返す。VMごと・関数ごとに生成した機械語バイト列またはコンパイル対象外の判定を保存し、実行用ページは呼び出しごとに確保・解放する。[Spinelとの呼び出し規約](../../lib/wardite/efflorescence/spinel_jit.rb)

## 完了の確認

wardite-benchesのRust版 `count_primes(1_000_000)` は、JIT有効で `MIR JIT function 0: compiled` を記録し、無効時と同じ `I32(78498)` を返した。E2Eテストには、上位32ビットまで使う二乗・比較、スピル、符号なし剰余、VMへの復帰後に元のゼロ除算が報告されるケースがある。[Rustの試し割り](https://github.com/udzura/wardite-benches/blob/921a69220eaad620ecc033013f4171e5b21eb8e7/rust/examples/count_primes.rs)・[JITのE2Eテスト](../../test/e2e/spinel_jit_test.rb)

この段階で対応した `i64` は試し割りの中間演算である。`i64` の引数・戻り値と数値命令全体、浮動小数点、メモリに書き込む篩法は次のADRで扱う。
