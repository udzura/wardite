# ADR 0030: MIR2 キャッシュキーの SHA-256 を Spinel の Arm SHA2 命令で高速化する

- **状態** 採用。Spinel のパッチ済みリビジョンを Wardite の CI・リリースビルドに固定する。
- **日付** 2026-11-22

## 背景

[ADR 0009](0009-efflorescence-mir2-cache-integrity-modes.md) の MIR2 キャッシュは、元の Wasm 全体の SHA-256 をキーに含める。同じパスの Wasm が変更されたときは別のキーを引く。[ADR 0029](0029-efflorescence-spinel-interpreter-costs.md) では、Ruby 4.0.9 の MIR2 と起動スナップショットが両方ヒットした場合も、プロセス起動から終了まで 147.65 ms かかった。

Wardite #89 の Ruby 4.0.9 を同じ条件で32回ずつ起動したところ、計測ビルドの中央値は 147.36 ms、無改変ビルドは 147.32 ms だった。MIR2 のキー生成・読み込み・関数の遅延復元に 79.51 ms かかり、そのうち元の Wasm の SHA-256 を含むキー生成が 47.37 ms を占めた。遅延復元を各区間から差し引くと、スナップショットの復元は 44.39 ms、復元後の Ruby の実行は 0.11 ms だった。このスナップショットでは Ruby がバージョンを出力する直前の WASI 呼び出しから再開する。[計測パッチと全サンプル](https://github.com/udzura/wardite-benches/pull/11)

## 決定

Wardite はキーを引く前に元の Wasm 全体をハッシュする。Spinel の SHA-256 ブロック圧縮で、リトルエンディアンの AArch64 コンパイル対象が SHA2 と NEON に対応する場合に Arm SHA2 命令を使う。汎用 AArch64 と `SP_PORTABLE` は従来の C 実装、x86-64 は既存の CPUID による実行時選択を使う。[Spinel #12380](https://github.com/matz/spinel/pull/12380)

Wardite は CI と Zig リリースビルドの Spinel を #12380 のパッチ済みコミット `a6454297079f25e7d1d4d0d094ffdd45b3d9ac0b` に固定する。upstream へのマージ後は、その変更を含むリビジョンに両方のピンを更新できる。問題があれば両方を #89 の `68476ebd3` に戻す。ダイジェストとキャッシュ形式は互換であり、切り戻し時にも同じ MIR2 とスナップショットを再利用できる。

## 比較検証

Apple M3 Pro で Wardite を同じ `3edaf5d` に固定し、Spinel `f341ce1bf` と、そこに Arm SHA2 の変更だけを加えた `954dc004b` を比較した。両ビルドで変更前に作った MIR2 と起動スナップショットを共有し、Wasm のハッシュと Ruby の出力を照合した。[検証コードと全サンプル](https://github.com/udzura/wardite-benches/pull/12)

| 区間（中央値） | 変更前 | Arm SHA2 |
|---|---:|---:|
| 読み込み済み Wasm 21,444,697 B の SHA-256（各64回） | 48.24 ms | 9.09 ms |
| 全キャッシュから Ruby を実行する新規プロセス全体（各32回） | 147.12 ms | 92.39 ms |
