# Efflorescenceの起動スナップショット

[ADR 0012](adr/0012-efflorescence-startup-snapshot.md)を実装した。WASIコマンドを `--new-engine --mir-cache DIR --snapshot DIR` で実行すると、ゲストが許可リストにないWASI関数を初めて呼ぶ直前の状態を保存する。同じキーの次回以降の実行では、Wasmの命令を実行せずにその時点から再開する。

```sh
WARDITE_TRACE=1 build/wardite --new-engine --mir-cache "$HOME/.cache/wardite" \
  --snapshot "$HOME/.cache/wardite" -- "$ruby_wasm" --disable-gems -e 'puts RUBY_DESCRIPTION'
```

`WARDITE_TRACE=1` で標準エラーに `snapshot saved`、`snapshot restored`、`snapshot miss`、`snapshot skipped (理由)` が出る。保存と復元には所要時間も付く。

チェックポイントより前にゲストが取得した時刻と乱数は、復元したすべての実行で同じ値になる。Rubyでは `Random` の既定のシードやハッシュのシードが固定される。信頼できない入力をハッシュのキーにする用途では使わない。

## 実装

- [Snapshot](../lib/wardite/efflorescence/snapshot.rb) がキーの計算、チェックポイントの判定、保存、検査と復元を行う。ファイルの読み書きは [MIRCache](../lib/wardite/efflorescence/mir_cache.rb) の `Reader`、`Writer`、`read_payload`、`publish` を共用する。
- キーは、スナップショットの形式バージョン、各メモリの現在のページ数、MIR2キャッシュのキー（Wasm全体のSHA-256、形式と生成コードのバージョン、最適化の無効化設定、ホスト識別子）、WASIの `snapshot_identity`（引数、環境変数、開いている全fdの番号と種別、preopenのパス）のSHA-256。
- [VM](../lib/wardite/efflorescence/vm.rb) の `CALL_HOST` と `CALL_INDIRECT` は、ホスト関数を呼ぶ間 `frame.pc` に命令の位置を保持する。`execute_flat` は `frame.pc` から始まる。`execute_host_site` は記録中だけ許可リストを判定し、公開呼び出しが入れ子でなければ保存する。判定は1プロセスで1回だけ行う。
- 復元は、Storeを通常どおり作った後、ファイルの全体を検査してからメモリとglobalを書き換え、`VM#resume` でフレームを積み直して最上位フレームのホスト呼び出しから再実行する。
- [ADR 0011](adr/0011-efflorescence-unboxed-globals.md)の整数配列とは、保存の直前にStoreへ書き戻し、`VM#resume` の開始時にStoreから読み込むことで同期する。
- 許可リストは `args_*`、`environ_*`、`fd_prestat_*`、`fd_fdstat_get`、`clock_res_get`、`clock_time_get`、`random_get` と、fd 0〜2に対する `fd_filestat_get`。
- startセクションを持つモジュールでは保存も復元もしない。

## 検証

- [efflorescence_snapshot_test.rb](../test/efflorescence_snapshot_test.rb) と [spinel_snapshot_test.rb](../test/e2e/spinel_snapshot_test.rb)：入れ子のフレーム、例外ハンドラ、`memory.grow`、i32とi64のglobal、`random_get` の後に、直接呼び出しと `call_indirect` のそれぞれでチェックポイントに入るWASIコマンドで、保存した実行と復元した実行の出力と終了コードが一致する。引数ごとに別のファイルになること、ペイロードを壊したファイルで通常の起動に戻り保存し直すこと、`--mir-cache` なしの指定を拒否することも確かめる。
- [verify_ruby_wasm.rb](../scripts/verify_ruby_wasm.rb) に `WARDITE_VERIFY_SNAPSHOT=1` を追加した。Ruby 4.0.9のWasmの `-e`、`require_relative`、`exit 7` の3ケースで、CRuby版とSpinel版それぞれの保存する実行と復元する実行がWasmtimeと一致した。
- CRubyのtest（281件）・型チェック、Spinelの回帰試験（82件）が通った。Wasmtimeを参照する `rake parity` は、手元のWasmtime 28.0.0が `-W exceptions` に対応していないため実行できなかった。CRubyとSpinelの間のparityは、`rake test` と `make spinel-test` に含まれるparity試験で確認した。

```sh
make spinel
WARDITE_VERIFY_SNAPSHOT=1 WARDITE_SPINEL_BIN="$PWD/build/wardite" \
  bundle exec ruby scripts/verify_ruby_wasm.rb "$ruby_wasm"
```

## 計測結果

Apple M3 Pro、macOS 26.6.2、Spinel `6f1a2c259`（`-O2`）。ゲストはRuby 4.0.9のWasm（SHA-256 `b1ee00286fc1efd27d8d9fd4ebe45034e74f006e37d4e759d77ea2f27ffc5a7e`）。すべてMIR2キャッシュのヒット。変更前（`94a60e5`）、変更後のスナップショットなし、変更後の復元の3条件を順に入れ替えながら各5回、別プロセスで実行し、中央値を取った。保存は既存のスナップショットを消して3回実行した。OSのファイルキャッシュは消去していない。ピークRSSは `/usr/bin/time -l` の最大常駐セット。

`-e 'puts RUBY_DESCRIPTION'`（スナップショット5.1 MiB）：

| 条件 | プロセス全体 | `load_from_buffer` | スナップショットの読み書き | ピークRSS |
|---|---:|---:|---:|---:|
| 変更前 | 1.51 s | 0.73 s | — | 1102 MiB |
| 変更後、スナップショットなし | 1.50 s | 0.71 s | — | 1024 MiB |
| 保存する実行 | 1.64 s | 0.71 s | 0.12 s | 1373 MiB |
| 復元する実行 | 0.81 s | 0.70 s | 0.08 s | 945 MiB |

`/app/main.rb`（`--mapdir`、スナップショット4.5 MiB）：

| 条件 | プロセス全体 | `load_from_buffer` | スナップショットの読み書き | ピークRSS |
|---|---:|---:|---:|---:|
| 変更前 | 1.50 s | 0.72 s | — | 1102 MiB |
| 変更後、スナップショットなし | 1.49 s | 0.70 s | — | 1021 MiB |
| 保存する実行 | 1.60 s | 0.70 s | 0.09 s | 1323 MiB |
| 復元する実行 | 1.26 s | 0.70 s | 0.06 s | 960 MiB |

`-e` では、復元する実行のプロセス全体が変更前より46%短い。残りの大半はMIR2キャッシュの読み込み（`load_from_buffer`）で、[ADR 0009](adr/0009-efflorescence-mir2-cache-integrity-modes.md)と[ADR 0010](adr/0010-efflorescence-mir2-cache-function-restore.md)の対象になる。スクリプトファイルでは、チェックポイントがスクリプトを開く `path_open` の直前（実行命令の31%の位置）になるため、短縮は16%にとどまる。

CRuby + YJITでも同じ `-e` で、MIR2キャッシュのヒットと復元を合わせたプロセス全体は1.94秒だった（1回の計測）。
