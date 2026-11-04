# Efflorescence VM: CALL / RETURNで型情報を保つ

2026-11-04、[フレーム初期化の軽量化](efflorescence-register-initialization.md)に続き、CALL / RETURNが参照するFrame、CallSite、poolの型情報を保つように改修した。
直前のコミット `fa4b14e` を独立してビルドした版と比較し、Spinelの `call_mix` は実行時間が15.4%、通常CLI全体では18.0%短縮した。

## 変更点

1. **poolの取得を添字アクセスに変える。** Spinelが扱えるオブジェクト配列の操作に揃えるため、`pools.fetch(index)` を `pools[index]` と明示的な存在確認に変えた。取り出したpoolをローカル変数へ入れてから `acquire` / `release` を呼ぶ。`(pools[index] || raise).acquire` の形では、この版のSpinelは呼び出し時に再び汎用の値へ変換していた。
2. **現在のFrameを返す境界を作る。** `VM#current_frame` の戻り値を `Wardite::Efflorescence::Frame` と明示した。現在のframeと、それを復元するスタックの型推論が循環して汎用の値になる問題を解消し、スタック自体もポインタ配列になる。
3. **CallSiteとFunctionの取得結果を具体化する。** `Function#call_site` と `IR#function_at` を追加した。Lowererは型が分かるFunctionを順に取得し、その具体的なレシーバーへ `install_code` を呼ぶ。渡すCallSite配列の型も維持され、実行時の `Function#calls` がポインタ配列になる。

`current_frame` は戻り値だけを注釈し、配列引数は推論させている。このSpinelでは、オブジェクト配列をメソッド引数の型として指定したシグネチャが適用されず、戻り値の注釈も含めて無効になる場合があるため。

新しい実行時コンテナ、命令、関数インライン化、共有フレームは追加していない。i32の表現、初期化範囲、フレームpoolの所有範囲も従来どおり。実装は通常のPure Rubyであり、Spinel固有APIや実行時コード生成は使わない。

## 生成Cの確認

同じSpinelで通常CLIのCを生成し、以下を確認した。

| 対象 | 改修前 | 改修後 |
| --- | --- | --- |
| `execute_flat` / `execute_semantic` の現在のFrame | `sp_RbVal` | `sp_Wardite__Efflorescence__Frame *` |
| フレームスタック | `sp_PolyArray *` | `sp_PtrArray *` |
| pool配列 | `sp_PolyArray *` | `sp_PtrArray *` |
| FunctionのCallSite配列 | `sp_PolyArray *` | `sp_PtrArray *` |
| flat実行ループのCallSite | `sp_RbVal` | `sp_CallSite *` |
| flat実行ループ内の `sp_pd_*` 呼び出し箇所 | 4 | 0 |
| flat実行ループ内の `sp_PolyArray_*` 操作箇所 | 13 | 0 |

最後の2行は生成ソースの静的な箇所数であり、実行回数ではない。FrameのPC・戻り先の読み書き、poolの取得・返却、CallSiteの参照で、汎用の値に対する型判定や多相ディスパッチが不要になった。

これはWasm関数全体の呼び出しコストが0になったという意味ではない。引数・戻り値の移動、PC・関数の切り替え、poolの空き一覧操作、GC rootの管理、MIRのCALL / RETURNディスパッチなどは残る。非flatのsemantic実行器には、MIR命令の参照・オペランド処理に関する多相呼び出しも残っている。

## Spinelの測定結果

macOS arm64、Spinel `2026.10.25+1967 (6e7fc1355)`、`-O2`、通常の整数overflowチェック。
5,000,000 rounds、seed 123、2回のウォームアップ後に7回測定した。単位はms、平均 ± 標本標準偏差。

| export | 改修前 | 改修後 | 実行時間の短縮 |
| --- | ---: | ---: | ---: |
| `empty_loop` | 119.751 ± 0.918 | 104.484 ± 0.739 | 12.7% |
| `call_identity` | 372.708 ± 8.990 | 304.378 ± 5.348 | 18.3% |
| `call_add_one` | 418.535 ± 9.810 | 338.836 ± 2.990 | 19.0% |
| `inline_mix` | 319.311 ± 1.910 | 299.152 ± 0.973 | 6.3% |
| `call_mix` | 590.542 ± 3.471 | **499.544 ± 7.903** | **15.4%** |

表は位相計測用workerの `call_unboxed` 実行時間。起動・ロード・MIR生成は含めず、公開呼び出しの準備とフレーム設定を含む。
MIRの型情報の改善は実行器全体のコード生成にも影響するため、inlineや空ループの改善分まで単独の「callコスト削減」とは解釈しない。

通常CLIの起動・ロード・変換・実行・出力を含む測定も、別プロセスで行った。

| export | 改修前のCLI全体 | 改修後のCLI全体 |
| --- | ---: | ---: |
| `inline_mix` | 324.455 | 301.835 |
| `call_mix` | 634.154 | **519.719** |

CLIとworkerは別エントリポイントであり、Spinelのプログラム全体の型推論・コード生成も異なる。両者の差をそのまま起動やロードだけの時間と解釈しない。

全サンプルで独立した参照計算とのchecksum一致を確認した。mixは `1647235310`、identityとempty_loopは123、add_oneは5000123だった。
MIRの動的ディスパッチ数・COPY数・レジスタ読み書き数・関数エントリ数・フレーム生成数も全5exportで両版が一致した。MIRカウンタは時間測定とは別プロセスで取得する。

## CRuby / YJITの確認

CRuby 4.0.9、100,000 rounds、seed 123、1回のウォームアップ後に3回の探索的な測定を行った。単位はms。

| 実行環境・export | 改修前 | 改修後 |
| --- | ---: | ---: |
| CRuby / inline_mix | 83.013 ± 0.221 | 83.655 ± 0.666 |
| CRuby / call_mix | 143.499 ± 0.629 | 143.257 ± 0.638 |
| YJIT / inline_mix | 39.729 ± 0.227 | 40.345 ± 0.338 |
| YJIT / call_mix | 62.759 ± 0.359 | 61.240 ± 0.756 |

大きな退行は観測しなかった。サンプル数が少なく、これらの小さな差を確定的な性能向上とは扱わない。採用判断はSpinelの長い測定を重視している。

## 正しさと再現手順

CRubyとSpinelのネイティブ実行を含め、**96 tests / 5,021 assertions、失敗・エラー・省略0**。型チェックとSpinelビルドも成功した。
元の受け入れベンチマーク全入力、各最適化の個別無効化、非flat実行、再帰、void呼び出し、引数・戻り値、再入、ローカル初期化、trap後の再実行を含む。
生成Cの回帰テストは、現在のFrame・スタック・pool・CallSite表の型と、flat実行ループから多相呼び出しが消えたことも確認する。

```sh
# 独立した直前の実装をビルドして比較
RUNS=7 WARMUPS=2 ruby benchmark/compare_call_types.rb 5000000 123

# CRuby / YJITも比較する場合
RUNTIMES=CRuby,YJIT RUNS=3 WARMUPS=1 \
  ruby benchmark/compare_call_types.rb 100000 123

make spinel
WARDITE_SPINEL_BIN="$PWD/build/wardite" bundle exec rake test
bundle exec rake check
```

デフォルトの対照は `fa4b14e` なので、そのコミットがローカルに必要。`BASELINE_REF` で変更できる。
ソースのスナップショットを作り、対照と現在版を別々にビルドする。保存済みビルドは、ソース・コンパイラ・フラグとバイナリのSHA256が一致する場合だけ再利用する。
全条件をラウンドロビンで測定し、各回で実行順を回転・反転する。全サンプルのchecksumを検証し、CLIも同じ入力を使う。

[Spinelの全サンプルとソース・バイナリのSHA256](../benchmark/results/call_types_spinel_2026-11-04.json)、
[CRuby / YJITの探索的なデータ](../benchmark/results/call_types_ruby_2026-11-04.json)を保存した。
Wasmの入力は `benchmark/i32_calls.wat` で、元のmix全体に差分測定用のループを加えたもの。生成Cやバイナリは再生成できる `build/benchmark/call-types/` 以下に置く。

通常の `ruby benchmark/compare.rb` も現在のソースを再コンパイルするため、この改修を含むNew VMを測定する。
