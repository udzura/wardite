# ADR 0010: MIR2キャッシュからの関数復元の高速化

- **状態** 提案
- **日付** 2026-11-12
- **前提** [ruby.wasm対応フェーズ2](0008-efflorescence-ruby-wasm-phase2.md)、[MIR2キャッシュの実装記録](../efflorescence-mir2-cache.md)

## 背景

MIR2キャッシュには、関数ごとのレジスタ型、初期レジスタ、定数レジスタ、フラット命令列、呼び出し・メモリ・例外の参照表が保存されている。[Decoder#decode](../../lib/wardite/efflorescence/mir_cache.rb) はヒット時に全関数（Ruby 4.0.9のWasmでは6049個）を順に復元し、続けて全関数の呼び出し引数と命令列を検査する。

Spinel版でキャッシュヒット時の起動を1回プロファイルした結果（1 ms間隔、1151サンプル）は次のとおり。

| 箇所 | サンプル数 |
|---|---:|
| `Decoder#decode` 全体 | 278 |
| うち `Reader#vector` と `String#unpack` | 約90 |
| うち boxed な配列から整数配列への変換（`sp_poly_as_int_array`） | 56 |
| うち GC | 約55 |
| うち `check_code` と `check_arguments` | 約65 |

`Reader#vector` は `String#unpack` を呼ぶ。Spinelではこの結果が boxed な配列（`sp_PolyArray`）になり、`function.bytecode.replace(code)` で整数専用配列（`sp_IntArray`）へ変換し直している。

## 決定

保存する内容は変えない。読み方を2段階で変える。

### 段階1: 整数配列への直接読み込み

Spinelでは、ペイロードを `IO::Buffer.for(payload)` で借り、`get_value` で1要素ずつ整数専用配列へ読む。boxed な中間配列を作らない。

- `Reader` に、格納先の整数配列を受け取る `read_into(target, format, width)` を追加する。Spinelでは `get_value(:s64, offset)` または `get_value(:s32, offset)` のループ、CRubyでは現行の `unpack` を使う。分岐は `RUBY_ENGINE == "spinel"` で行う（[StoreAccess#load](../../lib/wardite/efflorescence/store_access.rb) と同じ方法）。
- 命令列、初期レジスタ、定数レジスタ、呼び出し引数の読み込みをこのメソッドに置き換える。
- ファイル形式は変えない。

実装後、生成Cで `Decoder#read_function` に `sp_poly_as_int_array` と `sp_PolyArray_push` が残っていないことを確認する。

### 段階2: 関数単位の遅延復元

起動時に呼ばれる関数の割合が小さいことを前提にする。

**事前計測**: CRuby版で `--disable-gems -e 'puts RUBY_DESCRIPTION'` を実行し、`FramePool#acquire` が呼ばれた関数を数えた。定義された6049関数のうち943個（15.6%）だった。呼び出し638,683回の90%は121個の関数が占める。この結果から段階2に進む。スクリプトファイルの実行など別の起動条件でも同じ計測を行い、半分を超える条件があれば記録する。

**ファイル形式**: ペイロードの先頭に関数表を追加し、`FORMAT_VERSION` を更新する。関数表は関数ごとに、ペイロード内のオフセットとバイト長を持つ。

**読み込み時**: 関数表だけを読み、全関数について本体が未復元の `Function` を作る。`Function` はindex、引数型、戻り値型を宣言から得るので、呼び出し元の `CallSite` は未復元の関数を参照できる。ペイロードの文字列は `MIRCache` が保持し続ける。

**復元の契機**: 関数の最初のフレームを作るときに本体を復元する。[FramePool](../../lib/wardite/efflorescence/ir.rb) が新しいフレームを確保する経路に置き、実行ループ（`execute_flat`）には分岐を追加しない。

**検査**: 復元する関数の検査（`check_code`、`check_arguments`、参照表の検査）は復元時に行う。その関数の命令を1つも実行しないうちに終える。

**復元時に検査が失敗した場合**: すでにゲストの副作用が出ているため、再ビルドへは戻れない。キャッシュファイルのパスを含む例外を上げて実行を止める。利用者はファイルを削除して再実行する。

**全体検査との関係**: 整合性検査が `sha256` モード（[ADR 0009](0009-efflorescence-mir2-cache-integrity-modes.md)）のときは、読み込み時にペイロード全体を検査済みなので、復元時の失敗は実装の不具合を意味する。`checksum` モードでは、標本外の破損が復元時に見つかる可能性がある。

**即時復元の維持**: `--mir-cache-eager` で、読み込み時に全関数を復元・検査する現行の動作を選べるようにする。Ruby APIから `optimized_ir` や `dump_mir` を呼んだ場合も全関数を復元する。

## 検証

- 段階1・段階2とも、キャッシュ無効時と同じ結果になる（436フィクスチャのparity、CRubyとSpinel）。
- 段階2で、呼ばれなかった関数が復元されないこと、呼ばれた関数が実行前に検査されることを試験する。
- 段階2で、未復元の関数の本体を壊したキャッシュを使い、その関数を呼ぶ時点で例外になること、呼ばないケースでは正常に終わることを試験する。
- `call_indirect`、例外ハンドラ、ホスト関数経由の呼び出しでも、復元の契機を通ることを試験する。
- `--mir-cache-eager` で現行と同じ動作になる。

計測は、Ruby 4.0.9のWasmのキャッシュヒットで、`load_from_buffer`、プロセス全体、ピークRSSを変更前・段階1・段階2の各条件で3回以上、別プロセスで行う。

## 実装順

| 順 | 作業 | 確認 |
|---|---|---|
| 1 | Spinelで整数配列へ直接読み込む | 生成Cに boxed 配列の変換が残らない。`load_from_buffer` を計測する |
| 2 | 別の起動条件で、呼ばれる関数の数を計測する | 半分を超える条件の有無を記録する |
| 3 | 関数表の追加と遅延復元 | 上記の試験が通り、`load_from_buffer` とピークRSSを計測する |

## 受け入れ条件

- 段階1で `load_from_buffer` が変更前より短くなることを計測で示す。
- 段階2を採用する場合、起動全体が段階1より短くなり、ゲスト実行時間が退行しないことを示す。
- [verify_ruby_wasm.rb](../../scripts/verify_ruby_wasm.rb) の3ケースがWasmtimeと一致する。
- CRubyのtest・型チェック・parityと、Spinelの回帰試験が通る。
