# ADR 0017: Spinel版Efflorescenceの線形メモリloadを短縮する

- **状態** 提案
- **日付** 2026-11-17
- **基準** Wardite 1.2.2 `6c6348d`、Spinel `01a5d1bea`、`-O2`、既定の整数overflow検査
- **関連** [Spinel版の線形メモリ](../efflorescence-spinel-linear-memory.md)、[ADR 0008](0008-efflorescence-ruby-wasm-phase2.md)、[wardite-benchesのWASIサンプル](https://github.com/udzura/wardite-benches/tree/286de8be5226a4b41dc8e1b597b6717d761e9156#readme)

## 背景

WASIのBase64変換をSpinel版Warditeで計測した。入力はencodeが262,145バイト、decodeが349,528バイト。計測用のゲストで標準入力、変換、標準出力の前後に時計を読み、通常のWasmではプロセス全体と `WARDITE_TRACE=1` の `load_from_buffer` を記録した。macOS arm64、Rust 1.100.0-nightly `8fa1c96cf`、出力先は `/dev/null`。各条件を2回ウォームアップし、計測順を交替させた11回の中央値。

| 区間 | Encode | Decode |
|---|---:|---:|
| ロードとMIR準備 | 20.9 ms | 20.9 ms |
| 標準入力 | 0.49 ms | 0.48 ms |
| Base64変換 | 36.4 ms | 32.5 ms |
| 標準出力 | 4.27 ms | 0.09 ms |

この区間計測は、encodeが末尾LFを出す変更の前に取った。実験で末尾LFを付けるとencodeの出力区間は4.37 msから0.07 msになった。前後比較では末尾LF付きのゲストとfixtureを固定する。変更後の再計測ではencode全体が61.7 ms、MIR2キャッシュヒット時は43.5 ms。decodeは57.8 msと38.8 msだった。キャッシュで減る約20 msは主にロード・MIR準備の費用で、変換ループには別の改善が必要になる。

元のゲストで入力を約8 MiBのバイナリに増やし、encodeとそのBase64を入力にしたdecodeのCPUサンプリングを各3回行った。encodeは1,913サンプルの35%が `iob_get_core`、decodeは1,478サンプルの29%が `sp_IOBuffer_get_i` にあった。両方とも `execute_flat` と `I64Arithmetic.calculate` が上位に入った。サンプルの割合は各関数内で観測したPCの比率。短縮幅は変更前後を同じ入力で計測して判断する。

| 元の固定入力でのMIR命令数 | Encode | Decode |
|---|---:|---:|
| 全命令 | 5,282,971 | 4,934,284 |
| `I32_LOAD8_U` | 349,580 | 349,594 |
| `I64_LOAD8_U` | 0 | 349,504 |
| `COPY` | 679,004 | 1,236,237 |

## 提案

Spinel版Efflorescenceのmemory 0のスカラーloadを対象にする。第一段階で符号なし1バイトload、第二段階で全幅のi64 loadを試す。各段階を個別に比較する。差分はSpinelの読み出しアクセサと、Efflorescenceのload分岐・`StoreAccess` の呼び出しに収める。

[VMのload分岐](../../lib/wardite/efflorescence/vm.rb#L922)から、[StoreAccess#loadと#load_i64](../../lib/wardite/efflorescence/store_access.rb#L117)を経由する。Spinelでは都度 `Memory#buffer` を取り、Wasmとしての範囲検査後に `IO::Buffer#get_value` を呼ぶ。最初に生成Cでアクセサの選択を確認し、実行バイナリでどの型とどのバッファ形態が遅いかを単体のfixtureで分ける。

### A. 所有バッファと公開スライス上の1バイトload

Spinel `01a5d1bea` の通常のインラインloadは、所有バッファの `data` があるときに通る。Warditeはgrow時に余裕容量を取ることがあり、その場合は公開サイズだけのスライスを `Memory#buffer` に置く。所有バッファと、その有効なスライスの両方で、`i32.load8_u` と `i64.load8_u` が同じ整数読み出しを使い、その値をレジスタに入れる経路を作る。32ビット・64ビット結果のどちらも1バイトをゼロ拡張する。

1. grow前の所有バッファとgrow後のスライスで、旧経路の呼び出し先を確認する。
2. Spinelの [IO::Bufferのインラインアクセサ](https://github.com/matz/spinel/blob/01a5d1bea/lib/sp_iobuffer.h) が持つview解決を再利用し、読み出し単位で有効な基底アドレスと公開長を取得する。有効性を確認できた場合にだけ直接読み、その他はチェック付きアクセサに渡して既存の例外を保つ。汎用アクセサに手を入れる場合はSpinel側で、借用Stringとスライスの既存契約もテストする。
3. 生成Cで符号なし8ビットの正常経路が、widthや戻り値の型を動的に判定せずに読み出せることを確認する。Wardite側で幅の分岐が残って短縮を妨げる場合は、対象opcodeの呼び出しだけを狭幅用に分け、範囲検査を共有する。経路の診断は生成Cの検査と計測用ビルドで行う。

### B. 全幅のi64 load

`i64.load` はlittle-endianの `:s64` として読む。測定に使ったSpinelでは64ビット型の取得にboxed経路が残る。64ビットホストで、符号付き64ビットを正確に保持できる型付き整数経路を試す。任意のWasm i64 bit patternは同じ64ビットの符号付きcarrierで表せる。有効な8バイトを、未整列でも正しく読める `memcpy` 相当と必要なbyte swapで読む。Spinelの `get_value(:u64)` や狭いホストの戻り値は従来どおり扱う。符号付き64ビットの特殊化を入れる場合は、推論と生成Cを一緒に確認する。

`f64.load` も同じbit carrierを使うため、共通経路に変更が入る場合は負のゼロとNaN payloadをreinterpretで比較する。`i32.load` など残りの幅は単体計測に含め、追加の特殊化はA・B後のプロファイルに基づいて決める。

## 守る契約

- 有効アドレスは符号なし32ビットのアドレスとmemarg offsetの広い和。加算を32ビットへ丸めない。現在の公開長を `length` として、`start <= length` かつ `width <= length - start` で全幅を検査する。範囲外は従来の `Wardite::EvalError` にする。Spinelの内部確保容量は境界判定に使わない。
- バッファはアクセスのたびに現在のものを使う。生ポインタや長さのキャッシュをloadの外へ持ち出さない。grow、ホストコール、ホストからの再入を経た次のloadには新しい公開バッファが見える。grow失敗時のバッファとページ数、ホストに渡した旧ビューの無効化は従来どおり。
- little-endian、非整列・ページ境界をまたぐ範囲内の読み出し、符号拡張とゼロ拡張、i64とfloatのビット列を保持する。CPUアーキテクチャに依存する未整列ポインタの直接参照は使わない。
- コンパイラ側の変更は既存の `IO::Buffer` APIで表現する。WarditeのCIで使うSpinelリビジョンに必要な変更があるかを確認し、upstreamへの変更とWardite側の差分を個別に評価する。旧ツールチェーンでは現行のチェック付き経路が機能する。

## 検証

[メモリ](../../test/efflorescence_m2_memory_test.rb)、[grow](../../test/efflorescence_m2_grow_test.rb)、[Spinelのメモリ](../../test/spinel/efflorescence_m2_memory.rb)と[grow](../../test/spinel/efflorescence_m2_grow.rb)の既存fixtureを使う。次のケースが不足していれば追加する。

| ケース | 確認する内容 |
|---|---|
| 1/2/4/8バイトのload | 符号拡張とゼロ拡張、非整列、ページを跨ぐアクセス、i64の最上位ビット |
| 範囲の末尾 | 幅ぶん入る最後のアドレスは成功、次のアドレスはtrap。大きなアドレスとoffsetの和がwrapして低いアドレスを読まない |
| growと公開スライス | 余裕容量の手前と公開末尾を区別。容量内のtransfer、再確保するgrow、失敗するgrowの前後で旧データ・新ページ・境界を確認 |
| 呼び出しを跨ぐgrow | ゲストcallee、ホストがgrowしてから復帰、ホストからの再入の後に、元のcallerが現在のバッファを読む |
| 数値のbit carrier | i64の全ビット1と最小値、floatの負のゼロとNaN payloadを整数へreinterpretして同一ビットを確認 |

`bundle exec rake test`、`bundle exec rake check`、`make spinel-test RUBY="bundle exec ruby"`、`bundle exec rake parity` を実行する。既存のMIR2キャッシュを復元した場合もWasmの結果とtrapが同じになることを確認する。Spinel側の変更では有効な所有バッファ、読み取り専用バッファ、非ゼロoffsetのスライス、無効化したスライス、境界外の読み出しで既存のIO::Bufferの結果または例外と照合する。

## 計測と受け入れ条件

- 同じ `base64_codec.wasm` とfixtureを変更前後で使う。末尾LF込みのencodeとバイナリのdecodeを、Wasmtimeおよび参照ファイルとバイト単位で照合する。Wasmと入力のSHA-256、Wardite・Spinel・Rustのリビジョンを記録する。
- Base64はキャッシュなしとウォームなMIR2キャッシュのヒットを別に測る。バイナリごとにキャッシュディレクトリを作る。前後のバイナリを交互に実行し、2回以上ウォームアップして9回以上の生値と中央値を残す。`WARDITE_TRACE` のロード時間と、ゲストの変換区間またはロード後の実行区間、プロセス全体を並べる。命令カウンターとネイティブのサンプリングは時間計測と別に取る。
- load単体は、入力・テーブル読み出しを含む `load8_u`、未整列の `i64.load`、既存 [i32メモリベンチ](../../benchmark/i32_memory.wat) を使う。所有バッファとgrow後の公開スライスの両方を測る。集計に使う値を返してWasmtimeと照合する。
- 採用する段階は、対象のload単体に加えて、encode・decodeの少なくとも一方の変換区間で反復して短縮を確認できること。もう一方の変換区間、他の幅のload、既存i32ベンチの実行・ロードは、変更前の計測範囲と比較して回帰を確認する。生成Cと計測値から、短くなった経路を対応付ける。
- A・Bを分けてレビューする。両段階で既存Wasm、既存MIR2キャッシュ、公開APIとの互換性を保つ。

前後比較のロードトレースと出力照合は `wardite-benches` のルートで実行できる。`WARDITE_BIN` は対象のSpinelバイナリの絶対パス。`MIR_CACHE` はそのバイナリ用のディレクトリ。キャッシュ付きのコマンドは事前に1回実行し、計測時のトレースでhitを確認する。

```sh
wasi=build/rust/wasm32-wasip1/release/examples
wasm="$wasi/base64_codec.wasm"
"$WARDITE_BIN" -- "$wasm" encode < build/fixtures/data.bin | cmp - build/fixtures/data.b64
"$WARDITE_BIN" -- "$wasm" decode < build/fixtures/data.b64 | cmp - build/fixtures/data.bin
WARDITE_TRACE=1 "$WARDITE_BIN" -- "$wasm" encode < build/fixtures/data.bin > /dev/null
WARDITE_TRACE=1 "$WARDITE_BIN" --mir-cache "$MIR_CACHE" -- "$wasm" encode < build/fixtures/data.bin > /dev/null
```
