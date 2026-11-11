# Spinel版Warditeの線形メモリ

[ADR 0008の6a](adr/0008-efflorescence-ruby-wasm-phase2.md#6a-spinelに書き込み可能なstringビューを実装)では、Spinelに `IO::Buffer.for(string) { |buffer| ... }` を追加し、Efflorescenceの `memory.fill` で書き込み可能なビューを使った。ブロック中はStringの変更を拒否する。正常終了と例外でロックを解除し、渡したバッファを解放する。凍結Stringは読み取り専用。Spinelの回帰フィクスチャをCRuby 4.0.9と照合した。

Spinel側のコミットは `255955a06a0311df92f6b422c69d65ff2f39fe6e`。WarditeのCIでは固定したSpinel `6e7fc13556709bf7d7ba4af5bd1d12bebc00733e` に `spinel/patches/0001-io-buffer-string-view.patch` を適用する。

Apple M3 ProのSpinel `-O2` で、初回のfillでページを確保してから256 MiBを3回埋めた。バイトループは628.70–632.33 ms、Stringビューと `buffer.clear` は4.13–4.67 msだった。Ruby 4.0.9のWasmは `-e 'puts RUBY_VERSION; puts 6*7'` を実行し、標準出力の `4.0.9` と `42` を確認した。
