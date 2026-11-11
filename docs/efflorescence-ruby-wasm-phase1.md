# Efflorescenceのruby.wasm対応フェーズ1

[ADR 0007](adr/0007-efflorescence-ruby-wasm-phase1.md) の実装記録。CRuby版とSpinel版で `--new-engine` を指定し、Ruby 4.0.9のWASI Preview 1コマンドを実行する。

- 共有WASIのimportはstart前に検証する。realtimeとmonotonicの時計、環境変数、`fdstat` のABIを修正した。ADRに列挙した10個の未実装APIは既知のシグネチャでリンクでき、呼び出すと `ENOSYS` を返す。
- MIRレジスタ検証は固定幅のビット集合と逆ポストオーダーを使う。基本ブロックの合流では定義集合を交差させ、ループと例外辺を含めて収束まで再検証する。
- CRubyの `memory.fill` は全範囲を検査してから、バイナリ文字列を最大64 KiBずつ書き込む。Spinelと、Store API経由で非バイナリ文字列が設定された場合はバイト単位で書く。
- `path_readlink` はホストのファイルシステムエラーをWASI errnoに変換する。`path_filestat_get` はlookup flagsを使い、第5引数の結果ポインタに `fd_filestat_get` と共通の形式で出力する。
- Spinel版も共有WASI実装を使う。POSIXのディスクリプタフラグとerrnoはFFIで取得・変換し、WASIの結果を既存の線形メモリへ書き戻す。WASIを無効にするには `--no-wasi` を指定する。

## ビルドと実行

検証に使ったRubyは `v4.0.9`（`3e93b23afcec3433f6aecc34b5d832799d754238`）。BASERUBY 4.0.2、WASI SDK 25.0、Binaryen 133、16 MiBのWasmスタックでビルドした。確認したWasmのSHA-256は `5d87d7e932b9b698892711f065d5e0313ad7aad96f88a9693d05aaae02541669`。生成物はビルド環境によって変わるため、比較には同じファイルを両ランタイムに渡す。

RubyのGitチェックアウトとWASI SDKの場所を `ruby_source`、`wasi_sdk_path` に指定する。ホストにRuby、autoconf、GNU makeとBinaryenを用意し、Warditeのルートから実行する。Warditeの実行と計測にはCRuby 4.0.9を使った。

```sh
build_root=$(mktemp -d)
mkdir -p "$build_root/src" "$build_root/build"
git -C "$ruby_source" archive 3e93b23afc | tar -x -C "$build_root/src"
(
  cd "$build_root/src"
  ruby tool/downloader.rb -d tool -e gnu config.guess config.sub
  ./autogen.sh
)
(
  cd "$build_root/build"
  WASI_SDK_PATH="$wasi_sdk_path" LDFLAGS="-Xlinker -zstack-size=16777216" \
    "$build_root/src/configure" --host=wasm32-unknown-wasi --with-static-linked-ext --with-ext=
  make -j8 ruby
)
ruby_wasm="$build_root/build/ruby"
wasm-tools validate "$ruby_wasm"
bundle exec ruby scripts/verify_ruby_wasm.rb "$ruby_wasm"
```

照合に使った参照エンジンはWasmtime 49.0.0（`17830bd3c`）。スクリプトは一時ディレクトリに `main.rb` と `answer.rb` を作り、各CLIを独立プロセスとして実行する。`bundle exec` で起動した場合はBundler適用前の環境を子プロセスへ渡す。Spinel版も照合に含めるには `WARDITE_SPINEL_BIN` を指定する。

```sh
make spinel
build/wardite --new-engine -- "$ruby_wasm" --disable-gems -e 'puts RUBY_VERSION; puts 6*7'
WARDITE_SPINEL_BIN="$PWD/build/wardite" bundle exec ruby scripts/verify_ruby_wasm.rb "$ruby_wasm"
```

Wasmtime、CRuby版Efflorescence、Spinel版Efflorescenceの3つで以下の結果が一致した。

| ケース | 標準出力 | 終了コード |
|---|---|---:|
| `--disable-gems -e 'puts RUBY_VERSION; puts 6*7'` | `4.0.9` と `42` | 0 |
| preopenの `/app/main.rb` から `require_relative` | `42` | 0 |
| `--disable-gems -e 'exit 7'` | 空 | 7 |

## 回帰試験

```sh
bundle exec rake test
bundle exec rake check
bundle exec rake parity
make spinel-test RUBY="bundle exec ruby"
```

CRubyのsuiteは258件、26,511 assertionsで失敗0件。Spinel専用76件はnative suiteで別に実行し、2,547 assertions、失敗・省略0件。型チェックも通過した。`rake parity` はwasm-tools 1.218.0とWasmtime 49.0.0を使い、CRubyとSpinelで各436 fixtureを検証した。Spinelのローカル版は `6f1a2c259`（`-O2`、既定のoverflowチェック）。

## キャッシュなしの起動時間

macOS 27.0.1 arm64、CRuby 4.0.9、YJIT有効で、同じWasmの `-e` を各構成2回、新規プロセスで実行した。比較元 `e9b922e` にはWASI起動時ABIとレジスタ検証の変更が入っている。計測対象の `e1a39ea` はSpinelホスト追加前のCRuby実装。この `-e` はファイル用のWASI APIを使わない。

```sh
baseline_dir=$(mktemp -d)
git archive e9b922e lib | tar -x -C "$baseline_dir"
for lib_path in "$baseline_dir/lib" lib lib "$baseline_dir/lib"; do
  /usr/bin/time -l bundle exec ruby --yjit -I"$lib_path" benchmark/measure_ruby_wasm_startup.rb "$ruby_wasm"
done
```

計測スクリプトは工程別時間を秒で出力する。ピークRSSはmacOSの `/usr/bin/time -l` が返すバイト数から換算した。起動全体はWardite CLIの実行開始から `_start` の完了までを指す。

| 工程 | 一括書き込み前の中央値（範囲） | フェーズ1の中央値（範囲） |
|---|---:|---:|
| Wasmデコード（秒） | 1.643（1.635–1.650） | 1.652（1.650–1.654） |
| Store初期化（秒） | 0.036（0.035–0.036） | 0.037（0.037–0.038） |
| MIR変換（秒） | 1.625（1.610–1.641） | 1.641（1.634–1.648） |
| MIR最適化（秒） | 4.527（4.469–4.584） | 4.490（4.484–4.496） |
| レジスタ検証（秒） | 7.721（7.700–7.743） | 7.732（7.726–7.739） |
| Lowering（秒） | 0.674（0.670–0.678） | 0.685（0.676–0.694） |
| ゲスト実行（秒） | 17.599（17.537–17.661） | 9.261（9.258–9.264） |
| 起動全体（秒） | 33.968（33.902–34.033） | 25.637（25.613–25.661） |
| ピークRSS（GiB） | 6.770（6.770–6.771） | 6.457（6.137–6.777） |

MIR2ビルドキャッシュと、ゲスト実行中の追加の性能改善は [フェーズ2](adr/0008-efflorescence-ruby-wasm-phase2.md) で扱う。
