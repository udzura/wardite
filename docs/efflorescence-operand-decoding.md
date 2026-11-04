# Efflorescence VM: 未使用オペランドを読み出さない

2026-11-04、`-O2` 固定で、flat実行器のオペランド読み出しを比較した。
対照は直前の `5924537`。`call_mix` の実行時間は4.4%、通常CLI全体では6.4%短縮した。

## 変更点

以前は、どの命令でもopcode・a・b・cの4ワードを読み出してから分岐していた。
現在は共通部分でopcodeとaを読み、b/cは必要な命令だけが取得する。

| 命令 | 以前の読み出し数 | 現在の読み出し数 |
| --- | ---: | ---: |
| RETURN / BR | 4 | 2 |
| COPY / I32_EQZ / BR_IF / BR_IF_ZERO | 4 | 3 |
| 算術 / CALL / PROFILE | 4 | 4 |
| TRAP | 4 | 2 |

TRAPでも共通ヘッダーのaは取得するが、使わないb/cは読まない。
読み出す値には従来どおり `Array#fetch` を使い、境界チェックを維持する。
命令幅は4ワードのままで、分岐先・レジスタ番号・CALLの引数ソース表現を変更しない。

PCは通常命令の処理後に4進める。分岐を取る場合、CALL、RETURNはPCを設定して次の反復へ移るため、共通の加算を通らない。
CALLは呼び出し元の復帰先を `pc + 4` として保存する。semantic実行器は変更していない。

## 先に比較した実装

最初は、共通部分でPCを先に4進め、各命令が `pc - 2` / `pc - 1` からb/cを取得する形にした。
100万回・ウォームアップ1回後に3回の探索的測定では、call_mixが93.843 → 93.206 msで差が小さく、inline対照は56.755 → 57.954 msと遅くなった。

読み出してからPCを進める形では、同条件の別の対照測定でcall_mixが93.322 → 87.422 msだった。
この版を以下の長い測定に使った。行や実験をまたぐ絶対時間の比較は避ける。
[両実験の全サンプルと、5924537に対する各パッチ](../benchmark/results/operand_decode_exploratory_2026-11-04.json)を保存した。

## Spinelの比較

macOS arm64、Spinel `2026.10.25+1967 (6e7fc1355)`。
両版とも明示的に `SPINELFLAGS=-O2` とし、通常の整数overflowチェックを使う。
5,000,000 rounds、seed 123、ウォームアップ2回後に7回測定した。単位ms、平均 ± 標本標準偏差。

| export | 改修前 | 改修後 | 実行時間の短縮 |
| --- | ---: | ---: | ---: |
| `empty_loop` | 104.594 ± 2.270 | 94.384 ± 2.716 | 9.8% |
| `call_identity` | 280.698 ± 4.836 | **257.311 ± 4.999** | **8.3%** |
| `call_add_one` | 320.028 ± 7.529 | **302.792 ± 4.635** | **5.4%** |
| `inline_mix` | 290.618 ± 7.831 | 287.863 ± 15.656 | 0.9% |
| `call_mix` | 482.231 ± 12.362 | **460.842 ± 5.859** | **4.4%** |

inlineの差は測定のばらつきの範囲であり、改善を主張しない。
通常CLI全体の平均は、inlineが300.856 → 293.664 ms、callが499.032 → 467.310 msだった。
CLIとworkerは別エントリポイントであり、Spinelのコード生成も異なるため、差をそのまま起動・ロード時間とは解釈しない。

全サンプルのchecksumは独立した参照計算と一致した。mixは `1647235310`。
MIR命令数・COPY数・仮想レジスタの読み書き数・フレーム生成数は両版で一致し、詳細カウンタは別のプロセスで取得する。
[全サンプル、コンパイラ設定、ソース・バイナリのSHA256](../benchmark/results/operand_decode_spinel_2026-11-04.json)を保存している。

## 読み出し削減の確認

Ruby上では、整数だけを保持するArrayの派生クラスで `fetch` を記録し、実際のワード読み出し位置をテストした。
RETURN / BRでb/c、COPY / EQZ / 条件分岐でcを読まないこと、CALLから復帰して次の命令を実行すること、PROFILEが3オペランドすべてを読むことを確認する。

mix全体も0・1・10回で記録し、読み出し数がinlineで `25 * rounds + 8`、callで `31 * rounds + 8` となることを確認した。
以前はすべての命令で4ワード取得していたため、それぞれ `28 * rounds + 12`、`36 * rounds + 12` だった。
5,000,000回の同じ制御フローでは、inlineが140,000,012 → 125,000,008、callが180,000,012 → 155,000,008ワードとなる。
大きな回数の値は式から求めたものであり、時間測定中にカウンタを入れたものではない。仮想レジスタへのアクセス数とも区別する。

生成Cでも共通部分の命令バッファ参照が4回から2回になったことを確認した。
Frame・スタック・pool・CallSite表の型情報と、flat実行ループ内の多相呼び出し0箇所も維持している。

## CRuby / YJITと検証

CRuby 4.0.9、100,000 rounds、seed 123、ウォームアップ1回後に3回の探索的な比較をした。単位ms。

| 対象 | 改修前 | 改修後 |
| --- | ---: | ---: |
| CRuby / inline_mix | 83.483 ± 0.267 | 75.610 ± 0.415 |
| CRuby / call_mix | 137.440 ± 0.712 | 125.597 ± 0.675 |
| YJIT / inline_mix | 38.775 ± 0.128 | 35.742 ± 0.118 |
| YJIT / call_mix | 59.639 ± 0.177 | 54.484 ± 0.562 |

サンプル数が少ないため、一般的な改善率は断定しない。[全サンプル](../benchmark/results/operand_decode_ruby_2026-11-04.json)を保存した。

ネイティブSpinelを含む全体で **105 tests / 5,741 assertions、失敗・エラー・省略0**。
型チェックと `-O2` のSpinelビルドも成功した。
新しい読み出しテストに加え、元の受け入れベンチマーク全入力、各最適化の個別無効化、分岐の両経路、0・複数引数、再帰・相互再帰・再入・trap後の再実行も検証する。

```sh
BASELINE_REF=5924537 SPINELFLAGS=-O2 RUNS=7 WARMUPS=2 \
  ruby benchmark/compare_call_types.rb 5000000 123

RUNTIMES=CRuby,YJIT BASELINE_REF=5924537 SPINELFLAGS=-O2 RUNS=3 WARMUPS=1 \
  ruby benchmark/compare_call_types.rb 100000 123

SPINELFLAGS=-O2 make spinel
WARDITE_SPINEL_BIN="$PWD/build/wardite" bundle exec rake test
bundle exec rake check
```

対照のコミットはローカルに必要。通常の `ruby benchmark/compare.rb` にも改修は反映される。

## インライン化について

今回の変更は関数のインライン化を行わない。
Wasmtimeには[関数インライン化の設定](https://github.com/bytecodealliance/wasmtime/blob/v49.0.0/crates/wasmtime/src/config.rs)があり、手元の49.0.0でも `wasmtime -C help` に `inlining` の指定があることを確認した。
ただし、このベンチマークでmixへのインライン化が実際に適用されているかは未確認。
Efflorescenceに導入する場合は、関数呼び出し自体の改善と区別できるよう、独立パスとして有効・無効を比較する。
