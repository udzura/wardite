# EfflorescenceのMIR2キャッシュ

[ADR 0008のフェーズ5](adr/0008-efflorescence-ruby-wasm-phase2.md#5-mir2ビルドキャッシュ)を実装した。CRubyとSpinelで `--new-engine --mir-cache DIR` を指定すると、同じWasmとMIR設定で別プロセスからlowering済みのコードを再利用する。

```sh
WARITE_TRACE=1 bundle exec ruby -Ilib exe/wardite --new-engine --yjit \
  --mir-cache "$HOME/.cache/wardite" -- "$ruby_wasm" --disable-gems \
  -e 'puts RUBY_VERSION; puts 6*7'
```

`WARITE_TRACE=1` で標準エラーに `MIR2 cache miss` または `MIR2 cache hit` が出る。Ruby APIでは `engine: :efflorescence, mir_cache: directory` を渡す。ヒットの有無は `instance.runtime.mir_cache_hit` で確認できる。`--mir-dump` と `--mir-profile` は通常のビルドを使う。Ruby APIでヒット後に `semantic_ir`、`optimized_ir`、`dump_mir` を呼ぶと、その時点で検査用のMIRを生成する。

## 形式と再リンク

Wasm全体のSHA-256、形式バージョン、生成コードの互換バージョン、重複や順序を正規化した無効化設定からファイル名を決める。Spinelのキーにはホスト識別子を加えるため、同じディレクトリでも各ホストは自身が生成したファイルを使う。ヘッダーに同じキーとペイロードのSHA-256を持つ。ペイロードはlittle-endianの整数と長さ付きベクタで、import名と全関数のシグネチャを含む構成に続けて、各関数のレジスタ、4ワード固定幅の命令列、呼び出し・例外・bulk memoryの参照表を保存する。i64とf64のキャリアは符号付き64ビットで保存し、f32のビット列もそのまま保持する。

Wasmデコード、import確認、Store初期化を毎回行う。読み戻し時に構成、ファイルサイズ、個数、opcode、コード幅、参照index、分岐先を確認する。関数とWASI callableの参照を今回のインスタンスに解決し、Wasmのstartセクションを実行してからCLIが `_start` を呼ぶ。

キャッシュには実行ユーザーが管理するローカルディレクトリを使う。ダイジェストは整合性の検査に使い、入力の信頼はディレクトリの管理者に置く。256 MiBまでのファイルを扱う。破損や読み取り失敗は再ビルドし、書き込みは同じディレクトリの一時ファイルからrenameする。保存先に書き込めなくてもビルド済みのコードで実行する。opcodeや参照表の意味、生成コードや検証規則を変更する際は `MIRCache::CODE_VERSION` を更新する。

## 再現手順

`ruby_wasm` に[フェーズ1でビルドしたRuby 4.0.9のWasm](efflorescence-ruby-wasm-phase1.md)を指定する。次の検証ではWasmtime、CRubyとSpinelそれぞれの通常実行とキャッシュ再利用を別プロセスで比較する。

```sh
make spinel
WARDITE_VERIFY_MIR_CACHE=1 WARDITE_SPINEL_BIN="$PWD/build/wardite" \
  bundle exec ruby scripts/verify_ruby_wasm.rb "$ruby_wasm"
```

macOSでは以下を、新しいキャッシュディレクトリで各3回計測した。各組で保存直後に別プロセスのヒットを測った。OSのファイルキャッシュは消去していない。`/usr/bin/time -l` の最大常駐セットをピークRSSとした。

```sh
for sample in 1 2 3; do
  cache=$(mktemp -d)
  /usr/bin/time -l ruby --yjit -Ilib benchmark/measure_ruby_wasm_startup.rb "$ruby_wasm"
  for mode in miss hit; do
    WARITE_TRACE=1 /usr/bin/time -l ruby --yjit -Ilib \
      benchmark/measure_ruby_wasm_startup.rb "$ruby_wasm" --mir-cache "$cache"
  done
  wc -c "$cache"/*.mir2
done
```

## CRubyの計測結果

Apple M3 Pro、macOS 27.0.1、CRuby 4.0.9 + YJIT。ゲストはフェーズ1と同じRuby 4.0.9のWasm（SHA-256 `5d87d7e932b9b698892711f065d5e0313ad7aad96f88a9693d05aaae02541669`）。各条件とも3回の中央値。MIR2生成は変換・最適化・レジスタ検証・loweringの合計で、キャッシュ読込は整合性と構造の検査を含む。

| 条件 | Wasmデコード | Store初期化 | MIR2生成 | キャッシュ読込 | キャッシュ保存 | 実行直前まで | ゲスト実行 | プロセス全体 | ピークRSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 無効 | 2.50 s | 0.16 s | 23.18 s | — | — | 26.11 s | 13.83 s | 40.47 s | 6.78 GiB |
| ミスして保存 | 2.51 s | 0.16 s | 21.72 s | <0.01 s | 1.21 s | 25.94 s | 14.49 s | 40.88 s | 6.86 GiB |
| 別プロセスでヒット | 2.56 s | 0.16 s | — | 1.87 s | — | 4.92 s | 13.04 s | 18.36 s | 5.49 GiB |

キャッシュは各回とも82,962,773 bytes（79.12 MiB）。ヒット時の実行直前までの範囲は4.85–5.17秒、プロセス全体は17.90–18.73秒だった。

## Spinelの計測結果

同じWasmをSpinel `6f1a2c259`（`-O2`、既定のoverflowチェック）で各2回、別プロセスとして実行した。各組でミスの直後にヒットを測り、OSのファイルキャッシュは消去していない。この表は、呼び出し参照表の専用配列を復元する前の計測。

| 条件 | 実行直前まで | プロセス全体 | ピークRSS |
|---|---:|---:|---:|
| Spinel対応前 | 14.36–15.79 s | 17.81–19.58 s | 9.55–10.88 GiB |
| キャッシュ無効 | 13.31–14.08 s | 16.58–17.68 s | 9.51–11.30 GiB |
| ミスして保存 | 15.03–15.40 s | 18.38–19.14 s | 9.35–9.88 GiB |
| 別プロセスでヒット | 4.67–4.76 s | 8.21–8.55 s | 6.41 GiB |

キャッシュは79.12 MiB。最終ビルドの追加計測では、起動全体は無効15.51秒、ミス17.37秒、ヒット8.91秒だった。この追加計測では回帰試験を並行して実行した。生成Cでは実行ループの命令列と呼び出し引数に `sp_IntArray`、直接呼び出しの参照表に `sp_PtrArray` を維持した。

## 回帰試験

Ruby 4.0.9のWasmでは、別プロセスのキャッシュヒットで `-e`（`4.0.9` と `42`、終了0）、`require_relative`（`42`、終了0）、`exit 7`（標準出力なし、終了7）がWasmtime、キャッシュ無効のCRuby、Spinelと一致した。

キャッシュの回帰試験で、startの副作用、インスタンスごとのメモリ・global、別callableへの再リンク、trapと例外処理を確認した。Wasm・互換バージョン・最適化設定による失効、破損・不正indexからの再ビルド、2プロセスの同時保存、書き込み不可、MIRダンプ・プロファイル時の迂回も確認した。

CRubyのテストと型チェック、Spinelの77件の回帰試験、Wasmtimeを含む436フィクスチャの命令パリティが通った。同じ436フィクスチャについて、CRubyのデフォルト最適化と全最適化無効の両方で、別プロセスのキャッシュミスとヒットの観測結果も照合した。

Spinelのキャッシュを追加した後も、Spinel自身が保存したファイルのヒットでRuby 4.0.9の3ケースがWasmtimeと一致した。小さいWasmでは、切り詰めたファイルの再生成、例外参照と数値ビット列の復元、WASIの出力と終了コード、`--help` の表示を回帰試験に加えた。
