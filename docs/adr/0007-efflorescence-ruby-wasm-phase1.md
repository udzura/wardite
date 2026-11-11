# ADR 0007: Efflorescenceのruby.wasm対応フェーズ1

- **状態** 実装・検証済み。[実装記録](../efflorescence-ruby-wasm-phase1.md)
- **日付** 2026-11-11
- **基準** main `9e75f91`、[M6 ADR](0006-efflorescence-m6-coverage-parity.md)
- **後続** [ruby.wasm対応フェーズ2](0008-efflorescence-ruby-wasm-phase2.md)

## 決定

CRubyホスト上のEfflorescenceで、Ruby 4.0.9のWASI Preview 1コマンドを動かす。`--disable-gems -e` と、`--mapdir` で公開したディレクトリ内のスクリプトからの `require_relative` を受け入れ条件とする。M6で対応した命令と共有WASI実装を使う。既定エンジンはStack VMとし、RubyGemsを有効にした配布構成、Preview 1全API、Spinel上のWASI、MIR2キャッシュは対象外とする。

調査ではRubyの `3e93b23afc` をWASI SDK 25.0、Binaryen 133でビルドした。6,049定義関数と37個のWASI importを含む。同じWasmはWasmtime 49.0.0で実行でき、現行Efflorescenceでは最初の欠落import `clock_res_get` でリンクに失敗する。一時的なWASIの補完、レジスタ検証の変更、ファイルAPIの修正で両方の受け入れケースが通った。今回のバイナリで新規Wasm命令は必要なかった。ビルド手順は [RubyのWASIポート](https://github.com/ruby/ruby/blob/master/wasm/README.md) を参照する。

## 1. WASIのリンクと起動時ABI

- [共有WASI実装](../../lib/wardite/wasi.rb) で `clock_res_get` を実装し、`clock_time_get` とともに realtime と monotonic の両クロックを扱う。返却値はu64 little-endianのナノ秒。未対応IDと境界外の結果ポインタをWASI errnoで返す。
- `environ_sizes_get` と `environ_get` は同じ `key=value\0` 表現のバイト数を使う。環境が空のときはデータを書かない。`fd_fdstat_get` は24バイトの `fdstat` を返し、filetypeをオフセット0、flagsを2、rightsを8と16に置く。ABIの検証には書き込み範囲の前後も含める。
- 残り10個の欠落importは `fd_advise`、`fd_datasync`、`fd_fdstat_set_flags`、`fd_filestat_set_size`、`fd_pread`、`fd_pwrite`、`fd_renumber`、`fd_seek`、`fd_sync`、`poll_oneoff`。受け入れケースで使わないものは既知のPreview 1シグネチャでリンクし、呼ばれた場合は副作用なしで `ENOSYS` を返す。試験で呼ばれて正常系に必要と判明したものはその契約を実装する。未知のimportと不正なシグネチャはstart前に拒否する。

## 2. 大きな関数のレジスタ検証

[RegisterValidation](../../lib/wardite/efflorescence/register_validation.rb) のdefinite assignmentを、基本ブロックごとのビット集合と逆ポストオーダーのworklistで計算する。入口では引数・local・定数を定義済みとし、合流では到達した先行辺からの定義集合を積集合で併合する。変化したブロックだけを再検証し、ループも固定点まで処理する。例外辺にはその辺固有の書き込みを加え、正常終了時のCALL結果を持ち込まない。

到達不能コードの型・index検査、定数への書き込み拒否、定義前の読み出し拒否、例外ハンドラの検証を維持する。CRubyとSpinelで動く固定幅のワード配列を候補とし、試作で使った多倍長整数の表現を前提にしない。既存の小モジュールと、分岐・合流・ループを多く持つ大関数の双方で検証する。

調査では、同じビット集合を使って検証順序を変えると、YJIT無効での起動全体が約212秒から約52秒になった。変更後もYJIT有効時の検証に約7.2秒を要した。各値は試作の単発計測。製品コードではキャッシュなしでの検証時間、起動全体、ピークRSSを記録する。

## 3. memory.fillの一括書き込み

[StoreAccess#fill](../../lib/wardite/efflorescence/store_access.rb) は書き込み前に全範囲を検査し、値の下位8bitをバイナリ文字列として一定サイズのチャンクにまとめて書く。CRubyでは64 KiBを試作の起点とする。Spinelでは等価なバイト書き込み経路を検証し、既存経路も使える構成とする。

長さ0の終端、非ゼロの値、複数チャンクと端数、範囲外trap時のメモリ不変を検証する。調査では最大256 MiBのfillがあり、YJIT有効でゲスト実行が約18.0秒から約9.5秒に縮んだ。比較時は両方とも同じキャッシュを使い、fillの差だけを見る。

## 4. preopen経由のファイル実行

- `path_readlink` は通常のファイルやディレクトリに対して `EINVAL`、存在しないパスに対して `ENOENT` を返す。ホストの `SystemCallError` をゲストの実行境界まで伝播させない。symlinkの正常読み出しも確認する。
- `path_filestat_get` はlookup flagsに従って `stat` / `lstat` を選び、第5引数の結果ポインタにPreview 1の `filestat` を書く。`fd_filestat_get` と同じバイナリ表現を使い、時刻をu64のナノ秒で返す。
- `--mapdir HOST:/app` を使い、`/app/main.rb` が同じディレクトリの `answer.rb` を `require_relative` して `42` を出すケースを追加する。既存の `path_open`、`fd_read`、`fd_close` を含めてCLIから確認する。

## 実装順とコミット

各行を独立したコミットにし、対応する回帰試験と必要なRBSを含める。コミットメッセージには `Co-authored-by: Codex <codex@openai.com>` を付ける。

| 順 | 作業 | コミット時の確認 |
|---|---|---|
| 1 | WASIリンク、時計、環境変数、fdstat | importの正常・拒否、ABIのバイト列、既存WASIの回帰 |
| 2 | レジスタ検証 | MIRの拒否条件と例外辺の回帰、Ruby 4.0.9の `-e`、検証時間とピークRSS |
| 3 | `memory.fill` | 大きな範囲とtrap時の不変性、Ruby 4.0.9のゲスト実行時間 |
| 4 | ファイルAPIと `--mapdir` | Wasmtimeと同じ標準出力・終了コードで `require_relative` |

## 受け入れ条件

Ruby 4.0.9のビルド条件とWasmのSHA-256を記録する。基準は `--host=wasm32-unknown-wasi --with-static-linked-ext --with-ext=`、`LDFLAGS="-Xlinker -zstack-size=16777216"`、`make -j8 ruby` で、BinaryenのAsyncify後の実行ファイルを使う。Wasmはビルド手順と外部fixtureの指定で再現できるようにする。

同じWasmとfixtureを両ランタイムに渡す。`ruby_wasm` はビルド済みWasmのパス、`app_dir` は `main.rb` と `answer.rb` があるディレクトリとする。

```sh
wasmtime run "$ruby_wasm" --disable-gems -e 'puts RUBY_VERSION; puts 6*7'
bundle exec ruby -Ilib exe/wardite --new-engine -- "$ruby_wasm" --disable-gems -e 'puts RUBY_VERSION; puts 6*7'
wasmtime run --dir "${app_dir}::/app" "$ruby_wasm" --disable-gems /app/main.rb
bundle exec ruby -Ilib exe/wardite --new-engine --mapdir "${app_dir}:/app" -- "$ruby_wasm" --disable-gems /app/main.rb
```

`-e` の標準出力 `4.0.9` と `42`、`require_relative` の `42`、両ケースの終了コード0を照合する。`exit 7` でも終了コードを確認する。既存の `bundle exec rake test`、`bundle exec rake check`、`bundle exec rake parity`、`make spinel-test RUBY="bundle exec ruby"` を実行する。

時間計測は新規プロセスで複数回行い、WasmデコードとStore初期化、MIR変換・最適化・検証・lowering、`_start` 実行を分ける。ホスト・ツールの版、YJIT設定、中央値と範囲を記録する。試作値は固定の合否閾値に使わない。
