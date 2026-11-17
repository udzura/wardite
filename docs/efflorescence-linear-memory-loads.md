# ADR 0017の実装と計測

Aを採用した。Efflorescenceの `i32.load8_u` と `i64.load8_u` は、同じ `StoreAccess#load8_u` で現在の公開バッファを読み直す。生成Cの正常経路は、定数型 `sp_IOBuffer_load_i(source, 0, start)` から整数レジスタに値を渡す。Spinel側の変更は各アクセスで有効なビューを解決する。所有バッファ、読み取り専用バッファ、有効なスライスはインラインで読み出し、チェック付きアクセサが無効なビューや範囲外の例外を処理する。Warditeはその前にWasmとしての範囲を検査する。現在のCI固定版 `58ee6361` でも同じWasmの結果とtrapが得られる。スライスの高速化を配布時に有効にするには、Spinel側の取り込み後にビルドの固定リビジョンを更新する。

[Spinel側の変更（matz/spinel #12053）](https://github.com/matz/spinel/pull/12053)

Bは試作に留めた。64ビットターゲットで `:s64` と `:S64` を型付き整数として推論すると、既存の `i64.load` および `f64.load` が使う `:s64` は `sp_IOBuffer_get_x` から `sp_IOBuffer_load_i` に変わる。生成Cの定数型に対して `memcpy` と必要なbyte swapが使われる。非整列のload単体は所有バッファで18.41 → 17.59 ms、スライスで18.79 → 18.06 msだった。MIRカウンター別ビルドでは全幅の `I64_LOAD` はencodeで43,704回、decodeで15回だった。encodeの変換区間はキャッシュヒット時に37.62 → 37.13 msだったが、AとBだけの再計測では36.80 → 36.80 msだった。decodeで見えた小差は全幅loadの回数から説明できない。Wardite側でも全幅用のメソッドを分ける案を試したところ、grow後の `load8_u` 単体が約1%遅くなった。

## Base64

Apple M3 Pro、macOS arm64 27.2.1、Wardite `5baaf38`、Spinel `01a5d1bea` を基準とした。すべて `-O2` と既定の整数overflow検査でビルドした。Rustは `1.100.0-nightly (8fa1c96cf)`、Wasmtimeは49.0.0。各ケースはプリフライトで出力とキャッシュを確認した後に2回ウォームアップし、順序を反転させながら各11回計測した。キャッシュヒットはすべてトレースで確認し、キャッシュディレクトリはバイナリ別に作成した。計測時の標準出力は `/dev/null`。元のWasmと変換区間計測用のWasmで、それぞれ全ビルドの末尾LF込みencodeとバイナリdecodeをWasmtime・参照ファイルとバイト単位で照合した。

値は中央値（ms）。全体とロードは通常のWasmで計測し、変換は同じソースに `Instant` を追加した別のWasmで計測した。ロードは `WARDITE_TRACE` の `load_from_buffer`。ウォームキャッシュのロード時間には遅延復元のすべてが含まれるわけではない。

| 操作 | MIR2 | 全体 変更前 → A | ロード 変更前 → A | 変換 変更前 → A |
|---|---|---:|---:|---:|
| encode | なし | 65.14 → 63.90 | 21.86 → 21.25 | 38.47 → 38.10 |
| encode | ヒット | 45.77 → 44.50 | 1.56 → 1.55 | 38.15 → 37.62 |
| decode | なし | 66.38 → 64.00 | 23.93 → 23.87 | 35.28 → 34.06 |
| decode | ヒット | 40.81 → 39.52 | 1.52 → 1.54 | 33.96 → 32.62 |

変換の各組でAが短かったのはdecodeでキャッシュなし9/11回、ヒット11/11回だった。元のWasmの約16 MiB入力で別に1 ms間隔のサンプリングを3回ずつ実施した。decodeのメインスレッド約2,500サンプル中、`sp_IOBuffer_get_i` のPCは変更前のレポートで計60件表示され、Aでは各回の表示しきい値（5件）を下回った。生成Cとこのプロファイルは、grow後のチェック付き呼び出しの減少と整合する。

## load単体

400,000反復の [load単体fixture](../benchmark/linear_memory_loads.wat) と、1,600反復（409,600 load）の [既存i32 array_scan](../benchmark/i32_memory.wat) を実行し、チェックサムを毎回Wasmtimeとビット単位で照合した。`grown` は先頭で1ページ拡張して公開スライスを作った。各値はプロセス実時間からロードトレースを引いた中央値（ms）。全体とロードの生値もCSVに残した。

| ケース | 変更前 | Spinel側だけ | Wardite側だけ | A | A + Spinel B |
|---|---:|---:|---:|---:|---:|
| load8 lookup / owned | 22.71 | 22.90 | 23.09 | 22.93 | 23.09 |
| load8 lookup / grown | 24.41 | 23.36 | 24.16 | 23.05 | 23.28 |
| unaligned i64 / owned | 18.21 | 18.22 | 18.39 | 18.41 | 17.59 |
| unaligned i64 / grown | 18.52 | 18.44 | 18.67 | 18.79 | 18.06 |
| i32 + load16 / owned | 24.02 | 24.04 | 24.25 | 24.38 | 24.49 |
| i32 + load16 / grown | 26.47 | 24.90 | 26.91 | 24.80 | 25.02 |
| array_scan / owned | 16.72 | 16.77 | 16.81 | 16.94 | 16.80 |
| array_scan / grown | 17.68 | 17.13 | 17.95 | 17.28 | 17.33 |

load8の短縮は主にSpinel側のビュー解決による。Wardite側の幅固定を積み重ねるとgrow後はさらに0.31 ms短くなった。所有バッファでは一部のload中央値が0.2〜0.4 ms増え、変更前の範囲内だった。array_scanのロードの中央値は0.21〜0.22 msだった。

## 再計測

wardite-benches の基準は `286de8be5226a4b41dc8e1b597b6717d761e9156`。encodeがLFを1個追加し、decodeが入力末尾のLFを1個除く版を使用した。計測用Wasmでは `output.write_all(&transform(&input)?)?` の部分を以下に置き換え、同じRustリビジョンのrelease、`wasm32-wasip1`、`--features wasi` でビルドする。

```rust
let started = std::time::Instant::now();
let transformed = transform(&input)?;
let transform_ns = started.elapsed().as_nanos();
output.write_all(&transformed)?;
eprintln!("base64_transform_ns: {transform_ns}");
```

| 入力 | SHA-256 |
|---|---|
| base64_codec.wasm | `0b140a426dc6e67415d8f7c8240e62c7619817a9397081fcc130a485c516fd02` |
| 変換計測用Wasm | `c15e4f603170ae819a2fd13b519b949ef5b7227560abac01b8367d6e7734c0cd` |
| data.bin | `f393e1dd8fb34a6ccc8f465e0a580fe98a887f550b30933424b9fa81b883029b` |
| data.b64 | `975ffd3e04c420336df1b1b4a9f94e7e89662352ecedca523833ac804fbfb69c` |

```sh
python3 benchmark/compare_linear_memory_loads.py ../wardite-benches "$timed_wasm" \
  base="$before_bin" spinel-a="$spinel_a_bin" wardite-a="$wardite_a_bin" \
  a="$a_bin" spinel-b="$spinel_b_bin" b="$split_load64_bin"
```

[全条件の11回分の生値](../benchmark/results/linear-memory-loads.csv) と [A対Bの再計測](../benchmark/results/linear-memory-loads-stage-b.csv)。`spinel-b` はAの上に [SpinelのB試作](../benchmark/patches/adr0017-spinel-signed64.patch) を適用したビルド。最後の `b` はさらに [Warditeの全幅load分岐試作](../benchmark/patches/adr0017-wardite-split-load64.patch) を適用したビルド。

## 互換性

追加したネイティブ回帰は、ゲストcallee、ホストによるgrow、ホストからの再入を跨ぐloadを検査する。grow後のスライスで公開領域の末尾と未公開容量、未整列のページ跨ぎ、i64の全ビット1・最小値、f64の負のゼロ・NaN payloadを確認した。変更前のバイナリが作成したMIR2キャッシュをAおよびBで復元し、戻り値と範囲外trapが一致することを確認した。
