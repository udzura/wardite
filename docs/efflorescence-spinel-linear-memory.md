# Spinel版Warditeの線形メモリ

[ADR 0008の6a](adr/0008-efflorescence-ruby-wasm-phase2.md#6a-spinelに書き込み可能なstringビューを実装)では、Spinelに `IO::Buffer.for(string) { |buffer| ... }` を追加し、Efflorescenceの `memory.fill` で書き込み可能なビューを使った。ブロック中はStringの変更を拒否する。正常終了と例外でロックを解除し、渡したバッファを解放する。凍結Stringは読み取り専用。Spinelの回帰フィクスチャをCRuby 4.0.9と照合した。

Spinel側のコミットは `255955a06a0311df92f6b422c69d65ff2f39fe6e`。WarditeのCIでは固定したSpinel `6e7fc13556709bf7d7ba4af5bd1d12bebc00733e` に `spinel/patches/0001-io-buffer-string-view.patch` を適用する。

Apple M3 ProのSpinel `-O2` で、初回のfillでページを確保してから256 MiBを3回埋めた。バイトループは628.70–632.33 ms、Stringビューと `buffer.clear` は4.13–4.67 msだった。Ruby 4.0.9のWasmは `-e 'puts RUBY_VERSION; puts 6*7'` を実行し、標準出力の `4.0.9` と `42` を確認した。

## 6bの所有バッファ

Spinelでは各 `Wardite::Memory` が `IO::Buffer` を所有する。Storeのアクティブデータ、Stack VM、Efflorescence、WASIは同じ領域を読み書きする。Efflorescenceの数値load/storeはlittle-endianの型付きアクセサを使う。bulk memoryは全範囲を確認してから `copy`、`clear`、`set_string` を呼ぶ。Spinel版のStack VMでも、範囲外のstoreとbulk memoryは書き込み前にtrapし、`memory.fill` の値は下位8ビットを使う。

Spinelのホストコールバックでは `store.memories[0].buffer` で現在の `IO::Buffer` を取得する。バッファのサイズ変更、解放、所有権の移動は `Memory` が行う。ゲスト呼び出しの後は、growに備えてバッファを取り直す。成功したgrowは旧領域の内容を引き継ぎ、新規ページをゼロで初期化してから古いバッファを解放する。上限超過、ロック中、割り当て失敗では旧バッファとページ数を維持する。

CRubyのホストAPIは `Memory#data` のStringを引き続き使える。両ホストで `Memory#read_bytes(offset, length)` と `Memory#write_bytes(offset, bytes)` を使える。WASIではパス、iovec、ファイルI/Oに必要な範囲を検査し、必要なバイト範囲だけをStringに取り出す。

## ビルド

Spinel側では `a9a35b85d75ca273558f7e25a875cc240fc0f5a3` で、`IO::Buffer.new` の領域割り当て失敗を `Errno::ENOMEM` として伝える。WarditeのCIは固定したSpinelに両方のパッチを適用し、パッチのハッシュをツールチェーンキャッシュのキーに含める。同じ構成をローカルでビルドするには、Spinelのクリーンな作業ツリーを `spinel_src` に指定し、Warditeのルートから実行する。

```sh
git -C "$spinel_src" switch --detach 6e7fc13556709bf7d7ba4af5bd1d12bebc00733e
git -C "$spinel_src" apply "$PWD"/spinel/patches/*.patch
make -C "$spinel_src" deps
make -C "$spinel_src" all
make spinel SPINEL="$spinel_src/bin/spinel"
```

## 計測

Apple M3 Pro、macOS arm64、Spinel `6f1a2c259` を基準に各段階のパッチを適用し、`-O2` と既定の整数overflowチェックで測定した。Ruby 4.0.9のゲストはフェーズ1と同じWasm（SHA-256 `5d87d7e932b9b698892711f065d5e0313ad7aad96f88a9693d05aaae02541669`）。`_start` の計測区間は、インスタンス構築とargvの設定後からゲストの戻りまで。MIR2キャッシュは使用していない。

| Spinelのメモリ実装 | 256 MiB fill（3回の範囲） | Rubyの `_start`（2回の範囲） |
|---|---:|---:|
| Stringのバイトループ | 628.70–632.33 ms | 2.72–3.15 s |
| 6aのStringビュー | 4.13–4.67 ms | 2.16–2.45 s |
| 6bの所有バッファ | 3.52–3.58 ms | 1.74–1.75 s |

小さいWasmでの比較は、Efflorescenceのエクスポート実行だけを各3回計測した。i32の試験は同じ非整列アドレスへのstoreとloadを50万組行う。WASIの試験は4バイトの `fd_read`（`/dev/zero`）と `fd_write`（`/dev/null`）を5万組行う。両実装のチェックサムは一致した。

| 処理 | 移行前の中央値 | 所有バッファの中央値 |
|---|---:|---:|
| i32 load/store | 56.33 ms | 22.68 ms |
| WASI read/write | 133.06 ms | 107.31 ms |

## 検証

固定したSpinelに両パッチを適用してビルドし、17件の `IO::Buffer` フィクスチャを照合した。Warditeの型チェックと全272テスト（29,219 assertions、失敗・省略なし）が通った。CRubyとSpinelで各436件の命令パリティが通り、SpinelのStack VMで分類される差は47件から29件になった。

Ruby 4.0.9では、Wasmtime 49.0.0とCRuby・Spinelの `-e`、`require_relative`、`exit 7` の出力と終了コードが一致した。CRubyとSpinelでは通常実行に加え、各ホスト自身のMIR2キャッシュを別プロセスから読み戻した実行も照合した。

## memory.growの余裕容量

Spinel版ではWasmの現在ページ数と内部の確保容量を分ける。再確保時は要求ページ数の8分の1（最低1ページ）を足し、Wasmの上限以内に収める。余裕容量の確保に失敗した場合は要求サイズで再試行する。余裕容量内のgrowでは、`IO::Buffer#transfer` で割り当てを移し、既存バイトのコピーを省く。

ゲストとホストには現在のWasmサイズに収まる `IO::Buffer` だけを公開する。未公開のページは割り当て時のゼロを保持する。成功時は旧バッファと派生ビューを無効にする。ロック中、上限超過、必要サイズの割り当て失敗では元の状態を保持する。CRubyはStringの実装を使う。

### Ruby 4.0.9の起動

macOS arm64、固定Spinel `6e7fc135` と上記の両パッチ、`-O2` で比較した。変更前は `3d07b48`。同じWasmと同じ既存MIR2キャッシュを使い、`--disable-gems -e 'puts RUBY_VERSION'` の出力が両方とも `4.0.9` であることを確認した。OSのファイルキャッシュが温まった状態で、変更前後の実行順を入れ替えながら各5回計測した。

| 中央値 | 変更前 | 余裕容量あり |
|---|---:|---:|
| 起動全体 | 1.538 s | 1.225 s |
| ロード | 0.516 s | 0.518 s |
| ピークRSS | 5.114 GiB | 1.074 GiB |

別の計測用ビルドで各3回、ゲストの `_start` とgrowのコピーを測った。ゲストは両方とも20回拡張し、最後に4,813ページ（約301 MiB）に達した。既存領域のコピーは20回から3回、合計4.14 GiBから64.125 MiBになった。コピー時間の中央値は312 msから4.51 ms、`_start` の中央値は1.004 sから0.706 sだった。

既存の小さいWasmも、ウォームアップ後に各4回測定した。i32の `inline_mix`、i64の `alu`、`float_alu`、インライン化を無効にした `call_one`、Storeの `array_scan` と `copy_fill` は、出力が一致し、CLI全体の実時間の中央値の変化は−1.5%から+0.5%だった。`array_scan` の先頭で1ページ拡張してから走査した場合は117.9 msから118.3 msだった。

Spinelの回帰では、余裕容量内のgrowと再確保の両方でバイトの保持、ゼロ初期化、旧ビューの無効化を確認した。ゲストとホストの範囲外アクセス、ロック中のgrow、余裕容量の確保失敗からの再試行、必要サイズも確保できない場合の状態保持を検査した。GCストレス下でもこの回帰を実行した。CRubyとSpinelの回帰、型チェック、各436ケースの命令パリティ、およびRuby 4.0.9のWASI実行の照合が通った。
