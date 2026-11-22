# ADR 0029: MIR のバイト検索を融合し、整数配列の最適化を Spinel に委ねる

- **状態** 実装・レビュー中。Wardite [#87](https://github.com/udzura/wardite/pull/87) → [#88](https://github.com/udzura/wardite/pull/88) → [#89](https://github.com/udzura/wardite/pull/89)。[Spinel #12369](https://github.com/matz/spinel/pull/12369) はマージ済み。
- **日付** 2026-11-22

## 背景

今回の MIR 最適化では、使われない一時スロットを圧縮し、深さ 10,000 の再帰で関数のフレームを 199 → 5 スロットに縮めた。局所 CSE は実ワークロードで減る演算が少なく、`--mir-enable cse` で選ぶ実験機能とした。インライン化後に評価したパスのうち、Base64 のエラー位置を分岐先で設定する `exit_copy` を既定で有効にした。4 MiB decode のディスパッチは 42,302,637 → 38,632,614 回に減り、実行順を入れ替えた2系列で全体時間が 3.6%・3.8% 短縮した。`fold`、`cfg`、`dce`、`licm` は個別に有効化できる。[ADR 0026・#81](0026-efflorescence-unused-slots.md)・[ADR 0027・#82](0027-efflorescence-local-cse.md)・[ADR 0028・#83〜#86](0028-efflorescence-reduce-executed-instructions.md)

それでも 4 MiB の Base64 decode では iwasm と時間差が残った。同じ Wasm のゲスト内に時計を入れると、プロセス全体の差の約 91% が復号本体にあり、32文字ずつ処理するループに集中していた。そのループで Spinel の生成 C を実験用に変更すると、MIR レジスタの配列アクセスを簡略化した場合は 33.41 ms、線形メモリの参照経路を短くした場合は 26.47 ms、ディスパッチをまとめた場合は 14.45 ms 短縮した。これは同じ対照から各要因を単独で変えた値で、組み合わせると短縮幅も変わる。そこでインタプリタのまま、Wasm の意味を必要とする処理を Wardite で、一般の Ruby プログラムにも適用できる処理を Spinel で改善する。[区間計測](https://github.com/udzura/wardite-benches/pull/5)・[3要因の切り分け](https://github.com/udzura/wardite-benches/pull/6)

## 決定

1. **i64 のシフトを Spinel FFI で実行する。** 左シフトと論理右シフトは入力を C の `uint64_t` として扱い、シフト量の下位 6 ビットを使う。上位ビットが立つ値やシフト量が 64 以上のときも Wasm の結果を保てる。CRuby は既存の整数演算を使う。[#87](https://github.com/udzura/wardite/pull/87)
2. **2段のバイト検索と直後の等値分岐を一つの MIR ハンドラで実行する。** `I64_BYTE_LOOKUP_BR_EQ` は途中に分岐の入口がなく、二つの一時アドレスが各ロード以外で読まれず、変換表の基点を先に読んでも値が変わらないときに生成する。副表の参照も調べ、入力バイトと検索結果はレジスタに残す。Spinel では FFI の呼び出し中だけ線形メモリを借り、入力と変換表を順に境界検査する。表のアドレス加算は memory32 で折り返す。CRuby は通常のメモリ読み出しを使う。新命令に合わせて MIR2 のコード版を 15 に上げ、復元時の検証とプロファイルの計数も更新した。[#88](https://github.com/udzura/wardite/pull/88)
3. **配列の境界判定と GC root の扱いは Spinel で最適化する。** ローカルの受け手が既に root にあり、添字が nil を取り得る整数ローカルであることを証明できる1引数の `Array#fetch` では、受け手を守る一時 root を省く。整数配列の書き込みは範囲内を符号なし比較1回で判定し、負の添字・配列の拡張・凍結・nil に関する振る舞いを保つ。Wardite の CI とリリースビルドにはマージコミット `68476ebd3` を固定する。[Spinel #12369](https://github.com/matz/spinel/pull/12369)・[Wardite #89](https://github.com/udzura/wardite/pull/89)
4. **エクスポートは両エンジンで明示的に呼ぶ。** `Instance`、`Efflorescence::VM`、`Exports` から `method_missing` を取り除く。従来の `instance.add(1, 2)` は `instance.runtime.call("add", [1, 2])` に移行する。関数の有無は `runtime.callable?(name)`、メモリやグローバルの取得は `instance.exports["name"]` を使う。Spinel ではホストの mixin をコンパイル時に解決できる順に WASI を読み込み、ファイル記述子からの stat 取得には `IO` 型の引数を持つメソッドを使う。[#89](https://github.com/udzura/wardite/pull/89)

## 各変更の効果

旧 Spinel ピンに固定した12回の中央値では、4 MiB の復号ループは変更前 225.67 ms、シフト FFI で 223.47 ms、バイト検索と分岐の融合を加えて 195.71 ms だった。別実行の MIR プロファイルでは融合命令が 4,718,601 回実行され、ディスパッチは 38,632,715 → 33,914,114 回、スロット書き込みは 47,543,317 → 38,106,115 回になった。Spinel #12369 だけを旧ピンにバックポートした対照でも、#88 のループは 194.33 → 174.19 ms に短縮した。[段階別の比較とバックポート](https://github.com/udzura/wardite-benches/pull/7)

#89 の同じ Wardite ソースでピンだけを更新すると、復号ループは 197.52 → 176.37 ms（10.7%短縮）、decode 全体は 222.71 → 201.62 ms（9.5%短縮）だった。この比較には両ピンの間に入ったほかの Spinel 変更も含む。キャッシュ済みの ruby.wasm は MIR2＋スナップショットの既定の遅延復元で 154.1 → 152.3 ms、eager 復元で 330.4 → 338.2 ms だった。[ピン更新の実測](https://github.com/udzura/wardite-benches/blob/b58aa4540249d7a82811da8c4bc56958fcba0062/benchmark/base64-decode/ffi.md)

`method_missing` の効果は、同じ Spinel で3メソッドの定義だけを外して測った。PNG は 257.08 → 223.30 ms（13.1%短縮）、decode 全体は 213.55 → 201.52 ms（5.6%短縮）、32文字ループ単体は 180.56 → 180.75 ms だった。別ビルドで入口を計数すると Base64・PNG とも呼び出しは0回だった。フックが定義されると Spinel は通常の呼び出しにも受け手のクラスを判定するコードを生成する。この結果には、そのコード生成の違いが表れている。[対照実験・生データ・検証パッチ](https://github.com/udzura/wardite-benches/pull/8)

## iwasm・Wasmtime との比較

2026-11-22 時点の最新安定版を Apple M3 Pro（macOS 27.2.1、arm64）で比較した。Wardite は #89 の `3edaf5d`、Base64・PNG は MIR workers 8、JIT 無効。iwasm は fast interpreter、Wasmtime は Cranelift を使った。[WAMR 2.4.6](https://github.com/wasm-micro-runtime/wasm-micro-runtime/releases/tag/WAMR-2.4.6)・[Wasmtime 51.0.0](https://github.com/bytecodealliance/wasmtime/releases/tag/v51.0.0)

各欄は中央値（ms）。32文字ループは 4 MiB 分の反復全体をゲスト内で計時し、ほかは新規プロセスの起動から終了までを計った。各構成を1回ウォームアップし、実行順を変えながら 各12回測定した。

| 測定区間 | Wardite #89 | iwasm 2.4.6 | Wasmtime 51.0.0 |
|---|---:|---:|---:|
| 4 MiB Base64 decode・32文字ループ | 176.89 | 48.49 | 1.89 |
| 4 MiB Base64 decode・全体 | 199.58 | 55.27 | 21.81 |
| 4 MiB Base64 encode・全体 | 290.59 | 53.37 | 21.35 |
| 1024×1024 PNG・全体 | 217.96 | 42.92 | 29.21 |

decode 全体で Wardite にかかる時間は iwasm の 3.61 倍、Wasmtime の 9.15 倍だった。iwasm との時間差は全体で 144.31 ms、32文字ループで 128.40 ms あり、この入力では引き続き復号ループが差の大半を占める。今回の命令融合と Spinel の配列アクセス改善は JIT 無効でも効いた。残りの時間差のうち、さらに命令を融合して縮められる分は未検証である。

### ruby.wasm の起動

Ruby 4.0.9 の同じ Wasm とゲスト引数 `--disable-gems -e 'puts RUBY_DESCRIPTION'` を使い、毎回新規プロセスで終了までを測った。単位は ms、実行順を変えた各12回の中央値。OS のファイルキャッシュはウォーム。

| ruby.wasm の起動条件 | Wardite #89 | iwasm 2.4.6 | Wasmtime 51.0.0 |
|---|---:|---:|---:|
| オプションなし・永続キャッシュが空 | 2,134.72 | スタック不足 | 6,093.77 |
| オプションなし・自動キャッシュヒット | — | — | 101.86 |
| スタックを 1 MiB に指定 | — | 310.48 | — |
| 全キャッシュ復元・事前コンパイル済み起動 | 147.65 | — | 30.85 |

通常起動では各ランタイムの既定設定を使う。Wasmtime はどちらも同じ `wasmtime run ruby.wasm …` で、変えたのは自動キャッシュの中身だけ。ミスは毎回空のディレクトリで、コンパイルとキャッシュへの保存を含む。ヒットは測定前に同じ Wasm を1回実行して作ったキャッシュを使う。Wardite は通常起動で永続キャッシュを作らない。iwasm はこの Wasm が既定スタックで起動できないため、成功した条件を別行に示した。

最終行では Wardite は MIR2 と起動スナップショットを遅延復元し、Wasmtime は `wasmtime compile` で作った `.cwasm` を直接指定した。両方とも事前準備は計時外。

3ランタイムの出力を照合し、Base64 の2反復目の全32位置で不正文字のエラー位置と終了コードを確認した。Ruby 起動では、計時とは別のトレースで Wasmtime の自動キャッシュ、Wardite の MIR2 とスナップショットの復元を確認した。[Base64・PNG の検証](https://github.com/udzura/wardite-benches/pull/9)・[起動条件と生データ](https://github.com/udzura/wardite-benches/tree/f7b66c6/adr/0029)
