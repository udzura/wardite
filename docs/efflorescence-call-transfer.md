# Efflorescence VM: 引数搬送とpool参照の軽量化

2026-11-04、[CALL / RETURNの型情報を保つ改修](efflorescence-call-types.md)の続きとして調査・実装した。
対照は直前の `83a4b9c`。Spinelの `call_mix` は実行時間が5.4%、通常CLI全体では7.7%短縮した。

## 採用した変更

### 1引数の呼び出しでループを省く

flat CALLの4番目の整数スロットは未使用だった。Lowererが引数1個の呼び出しに、そのソースレジスタ番号を埋め込むようにした。

```text
CALL dst, call_site_index, single_source

single_source >= 0: callee.registers[0] = caller.registers[single_source]
single_source == -1: 0引数・複数引数用の一般経路
```

通常のディスパッチで既に読み出しているスロットを使うため、命令幅・opcode・MIR命令数を増やさない。
レジスタ0も有効なソースなので、判定は `> 0` ではなく `>= 0` とする。
CallSiteの引数配列は保持し、semantic MIR、計測、複数引数の受け渡しにも引き続き利用する。

### 一般経路の変数を実行器の外へ出す

0引数・複数引数のコピーは `CallSite#copy_arguments(target, source)` にまとめる。
このメソッドは整数配列を受け取り、引数の数を一度だけ取得してコピーする。

当初は実行器内に一般経路のループ・変数を置いたが、今回のSpinelではinline対照も含めて遅くなった。
一般経路を分離すると1引数の呼び出しでそのループを通らず、実行器側の生きたローカル変数やGC rootも増やさずに済む。

### poolのインデックスを保持する

CallSiteとFrameが、それぞれの関数のインデックスを `pool_index` として生成時に保持する。
CALLでは `site.callee.index`、RETURNでは `frame.function.index` の参照を省き、poolを直接取得する。
関数は各Frame / CallSiteの生存中に変わらないため、再利用時の更新は不要。

フレームの空き一覧・フレームスタック・PCと戻り先の保存方式は従来どおり。
実行中のフレームを再利用せず、poolは公開呼び出しごとに独立させる。
関数インライン化、共有レジスタ領域、新しい命令、実行時コード生成は追加していない。

## 探索的に試した方式

100万回・seed 123、ウォームアップ1回後に3回測定した。以下はworkerの `call_mix` 平均、単位ms。
各実験はその実験と同時に測った `83a4b9c` を対照にしており、行をまたいで絶対時間を比較しない。

| 実験 | 対照 | 候補 | 判断 |
| --- | ---: | ---: | --- |
| poolを深さと保持配列で管理し、返却時は深さを減らす | 99.330 | 99.171 | 差が不明確なため不採用 |
| 1引数専用経路、一般経路のループは実行器内 | 98.885 | 103.052 | 遅くなったため不採用 |
| 一般経路をCallSiteのメソッドへ分離 | 99.664 | 93.849 | 採用候補 |
| 呼び出し元Frameへ直接リンクし、返却時にリンクを消す | 101.797 | 99.582 | 追加効果が不明確。分散も大きいため不採用 |
| 直接リンクを次の呼び出しまで保持する | 98.770 | 93.309 | 引数経路だけの変更を上回る明確な証拠がなく不採用 |
| 引数経路の分離とpoolインデックスの保持 | 100.514 | 94.042 | 長い測定で確認 |

直接リンク版も1引数の経路変更を含む。引数変更のみの版と直接ペアで長時間比較したものではなく、リンク方式の改善を主張できる結果ではなかった。
poolインデックスの保持も、単独の寄与は切り分けていない。最終的な組み合わせを以下で検証する。

[探索的な全サンプルと各実験のパッチ](../benchmark/results/call_protocol_exploratory_2026-11-04.json)を保存した。
パッチはすべて `83a4b9c` に対する独立した差分で、累積ではない。

## 最終候補のSpinel計測

macOS arm64、Spinel `2026.10.25+1967 (6e7fc1355)`、`-O2`、通常の整数overflowチェック。
5,000,000 rounds、seed 123、ウォームアップ2回後に7回測定。単位ms、平均 ± 標本標準偏差。

| export | 改修前 | 改修後 | 実行時間の短縮 |
| --- | ---: | ---: | ---: |
| `empty_loop` | 104.049 ± 0.499 | 101.513 ± 0.482 | 2.4% |
| `call_identity` | 302.253 ± 3.342 | **272.513 ± 2.556** | **9.8%** |
| `call_add_one` | 341.324 ± 6.518 | **308.845 ± 0.742** | **9.5%** |
| `inline_mix` | 298.277 ± 0.339 | 285.036 ± 1.667 | 4.4% |
| `call_mix` | 495.396 ± 2.908 | **468.660 ± 8.552** | **5.4%** |

表はworkerの `call_unboxed` 実行時間。起動・ロード・MIR変換を含まない。
通常CLI全体では、inlineが300.540 → 291.632 ms、callが518.693 → 478.539 msだった。
CLIとworkerは別エントリポイントであり、位相時間をCLI時間から単純に引いて起動・ロード費用とは解釈しない。

薄い関数を多く呼ぶidentity / add_oneでは、mixより大きな割合の改善が観測された。
ただしinline対照も改善しており、差分すべてを単独の「call命令のコスト削減」とは解釈しない。

全測定で独立した参照計算とchecksumが一致し、MIRの動的命令数、COPY数、レジスタ読み書き数、関数エントリ数、フレーム生成数も全5exportで一致した。
詳細カウンタは別プロセスで取得し、時間測定には含めない。
[全サンプルとソース・バイナリのSHA256](../benchmark/results/call_protocol_spinel_2026-11-04.json)を保存している。

## Time Profilerによる確認

`-O2 -g -fno-omit-frame-pointer --no-line-map` の別ビルドで、`call_mix(50_000_000, 123)` を記録した。
両版のchecksumは `3380275835`。通常ビルドの性能比較と、この診断用ビルドの計測は分けて扱う。

改修前は `Function#parameter_count` 以下がCPUサンプルの約3.8%を占めた。
改修後はその関数と、その内部の汎用sizeディスパッチに対応するサンプルが見られなかった。
生成Cでもflat実行ループから `parameter_count` の参照がなくなり、1引数の経路は直接コピーになっている。
Frame・pool・CallSiteの型は維持され、flat実行ループの `sp_pd_*` 呼び出しは引き続き0箇所だった。

pool取得・返却のInclusive割合は、改修前が約3.6% / 2.3%、改修後が約3.7% / 2.3%だった。
割合は子の処理と重なり、他の処理が短くなっても変わるため、単独の速度比較には使わない。
GC root登録などの負荷も残る。[集計したCPUサンプル](../benchmark/results/call_protocol_profile_2026-11-04.json)を保存した。

## CRuby / YJITと正しさ

CRuby 4.0.9、100,000 rounds、seed 123、ウォームアップ1回後に3回の探索的な測定をした。
`call_mix` の実行時間はCRubyで144.418 → 137.707 ms、YJITで62.416 → 59.255 ms。
サンプル数が少ないため、この小さな測定だけで一般的な改善率を断定しない。
[CRuby / YJITの全サンプル](../benchmark/results/call_protocol_ruby_2026-11-04.json)も保存している。

CRubyとネイティブSpinelを含む全体は **99 tests / 5,703 assertions、失敗・エラー・省略0**。
型チェックとSpinelビルドも成功した。
追加テストで、ソースレジスタ0、0・1・2・3引数、void、引数の順序、引数と戻り先の重なり、相互再帰とローカル再初期化を確認した。
元の受け入れベンチマーク全入力、各最適化の個別無効化、再入、trap後の再実行も引き続き検証している。

## 再実行

```sh
BASELINE_REF=83a4b9c RUNS=7 WARMUPS=2 \
  ruby benchmark/compare_call_types.rb 5000000 123

RUNTIMES=CRuby,YJIT BASELINE_REF=83a4b9c RUNS=3 WARMUPS=1 \
  ruby benchmark/compare_call_types.rb 100000 123

PROFILE_DIR=build/benchmark/call-protocol/profile-after \
  ruby benchmark/build_call_profile.rb

make spinel
WARDITE_SPINEL_BIN="$PWD/build/wardite" bundle exec rake test
bundle exec rake check
```

対照のコミットはローカルに必要。通常の `ruby benchmark/compare.rb` も最新のソースを再コンパイルするので、この変更を含めて測定する。
