# Efflorescence: キャッシュ前のMIR生成性能調査

2026-11-15、Wardite `1de771d` を調査した。大きなWasmでは、まず**レジスタ検証とWasmデコードの一時オブジェクト・走査量**を減らす価値がある。最適化器では、個々の変換パスよりも**全IRを2回コピーする費用**が目立つ。大きなi32関数には別に、copy propagationの二次的な増加がある。

改修の具体的設計は[実装担当向け入口](efflorescence-mir-generation-implementation.md)と、そこから参照するADR 0014〜0016にまとめた。

## 測定範囲

現在の経路は `BinaryLoader.sections` → `CodeBody.check_features` → Store作成 → `Translator.link` → `Translator.translate` → `Optimizer.optimize` → `RegisterValidation.validate` → `Lowerer.compile`。MIRテキストのパーサーはなく、Wasmバイナリを命令配列にデコードしてからsemantic MIRを生成する。

`--mir-cache`、snapshot、`--mir-profile` は使わず、`load_from_buffer(engine: :efflorescence)` の開始から終了までを測った。worker起動時のrequire、プロセス起動・終了、統計の集計、ゲストのexport実行、キャッシュのキー計算・読み書きは含まない。load内の遅延requireは含む。start sectionを持たないfixtureだけを使用した。キャッシュを有効にした初回ミスではデコードが `check_features` に遅延されるため、このフェーズ分布をそのまま当てはめることはできない。

- ホスト: macOS 27.2.1 / arm64。CRuby 4.0.9、YJITなし。
- コンパイラ: Spinel `2026.10.25+5184 (01a5d1bea)`、`--strict-require -O2`、既定の整数オーバーフロー検査。
- 大入力: 手元の `tmp/ruby.wasm`、Ruby **3.4.2**（Wasmtimeで `RUBY_DESCRIPTION` を確認）。SHA-256 `1ac460e944a54c17529aa05e6cad4575aab6d3d2466745f935237f7a46351e98`。既存の起動改善資料で使ったRuby 4.0.9のWasmとは別のfixture。
- 小入力: `examples/i32_bench.wasm`、418 bytes。大きなi32関数は後述の生成fixture。
- 主計測: 各組み合わせ1回warmup、3回計測、毎回別プロセス。CRuby/Spinelの順序を交替し、OSファイルキャッシュは消去しない。CPU負荷をかける計測・ビルドは同時実行しない。
- タイマーは `CLOCK_MONOTONIC`。本番ソースのコピーへ挿入し、`lib/` 自体は変更しない。RSSはこの実行環境で `/usr/bin/time -l` が失敗するため未測定。

## 大きなWasmの内訳

秒、3回の中央値。割合はSpinelのload全体に対する概算。独立に求めた中央値なので各行の合計はtotalと厳密には一致しない。

| フェーズ | Spinel | 割合 | CRuby |
|---|---:|---:|---:|
| Wasmセクションのデコード | 3.012 | 26.2% | 4.056 |
| Wasm命令のfeature・block type確認 | 0.920 | 8.0% | 0.548 |
| Store構築 | 0.003 | <0.1% | 0.056 |
| 関数・ホストのlink | 0.002 | <0.1% | 0.020 |
| semantic MIR生成 | 2.094 | 18.2% | 4.069 |
| 最適化（コピーを含む） | 1.045 | 9.1% | 5.266 |
| レジスタ検証 | 4.200 | 36.5% | 19.559 |
| flat命令列へのlowering | 0.202 | 1.8% | 1.150 |
| **load全体** | **11.513** | **100%** | **34.731** |

load全体のmin–maxはSpinel **11.465–11.579秒**、CRuby **34.691–34.942秒**。translate以降のMIR生成だけなら約7.54秒で、その約56%がレジスタ検証。デコード・feature確認も合わせると、検証とWasm読み込みがload全体の約71%を占める。

semantic MIRは8,161関数、2,173,080命令、1,383,608レジスタ。最大の関数は24,568レジスタ。現行のローカル最適化対象は292関数（3.58%）、3,374命令（0.155%）に限られる。i64、float、EH、store操作、dynamic callのいずれかを使う関数は `Optimizer#optimize_function` の入口で除外される。最適化後は2,172,832命令で、削減は248命令（0.0114%）。これは静的命令数であり、ゲスト実行時間への効果は示さない。

小入力の `i32_bench.wasm` は2関数・41命令、最適化後29命令。Spinelでload全体0.553 ms、最適化0.141 ms、検証0.063 msだった。サブミリ秒の測定なので厳密な比率は不安定だが、この小入力の比率だけで大きなWasmの優先順位は判断できない。

詳細タイマーを追加したSpinelの別測定（warmup 1回＋3回）では、次の内訳だった。これらは**inclusive time**で、親子の行を足してはいけない。Analysisなど複数の呼び出し元を持つものは全呼び出しの合計。

| 詳細処理 | 中央値 | 回数/ロード |
|---|---:|---:|
| `BinaryLoader.code_body` | 2.980 s | 13,479 |
| `IR#copy` | 1.030 s | 2 |
| `Inlining#run`（2回目のIRコピーを含む） | 0.451 s | 1 |
| `CopyPropagation#run` | 0.00886 s | 297 |
| `ImmediateSpecialization#run` | 0.000075 s | 297 |
| `BranchFusion#run` | 0.00100 s | 297 |
| `Superinstructions#run` | 0.00105 s | 297 |
| `RegisterValidation#validate_types` | 0.659 s | 8,161 |
| `Analysis#initialize` | 0.513 s | 10,096 |
| `FlowGraph#initialize` | 0.778 s | 8,161 |
| `RegisterValidation#reverse_postorder` | 0.181 s | 8,161 |

詳細測定での最適化全体は1.042秒。その約99%が2回の `IR#copy` に費やされた。`code_body` の呼び出しには関数本体だけでなく、globalの初期化式なども含む。最適化パスの297回は初回292関数に、inline後の再最適化5回を加えたもの。

## 対照実験と割り当て

フェーズタイマーを外した同じworkerでもSpinelのload全体は11.421秒（11.172–11.848秒）。粗い計測の11.513秒、詳細計測の11.649秒と近いが、別系列の3回測定なので計測オーバーヘッドを厳密に推定するものではない。

タイマーなしでinlineだけを無効化すると10.805秒（10.716–11.087秒）だった。default/no-inlineを同じ回で対にした差の中央値は0.455秒で、詳細測定の `Inlining#run` 0.451秒と整合する。生成命令数は2,172,832→2,172,837。これは費用を切り分ける実験であり、inlineを無効にする推奨ではない。ゲスト実行速度は測っていない。

CRubyでの別の1回の診断では、ロード中に約**7,126万オブジェクト**が割り当てられた。GCは52回、`GC.stat(:time)` の増分は6.774秒。測定ラッパーとVernierも有効なため、主計測とは分けて扱う。オブジェクト数はバイト数やピークRSSではない。

| フェーズ | 割り当てオブジェクト数（inclusive） |
|---|---:|
| セクションデコード | 22,488,536 |
| semantic MIR生成 | 7,597,524 |
| 最適化 | 9,993,792 |
| └ 2回のIRコピー | 9,833,408 |
| レジスタ検証 | 30,862,889 |
| └ FlowGraph | 10,992,183 |
| lowering | 164,014 |

Vernierのself sample上位は `Opcode.read_positions` 10.4%、`Array#include?` 9.7%、`Instruction#[]` 6.5%、`Array#fetch` 6.5%、`RegisterValidation::Block#merge` 5.4%。Arrayのメソッドは複数の呼び出し元を含む。この比率をSpinelの時間へ直接換算はできないが、operand配列の再生成、membership走査、bitsetのmergeが調査対象になる。生データにある関数別wall timeには、その関数の処理中に発生したGC停止も含まれるため、短い関数が遅いという根拠には使わない。

## i32関数のサイズ依存性

1関数内で `local.get 0; i32.const 1; i32.add; local.set 0` をN回繰り返すfixture。メモリやi64を使わず、現行の最適化対象になる。詳細計測、warmup 1回＋3回の中央値、単位ms。

| N | MIRレジスタ数 | Spinel load全体 | Spinel最適化 | Spinel propagate | CRuby propagate |
|---|---:|---:|---:|---:|---:|
| 256 | 259 | 1.728 | 0.891 | 0.223 | 4.410 |
| 512 | 515 | 3.634 | 2.093 | 0.641 | 17.096 |
| 1,024 | 1,027 | 7.646 | 4.668 | 2.492 | 58.542 |
| 2,048 | 2,051 | 18.600 | 12.573 | 8.045 | 224.579 |

Nを8倍にするとpropagateはSpinelで約36倍、CRubyで約51倍になった。O(I×R)というコード上の走査と整合する超線形の増加であり、大きなi32関数ではこのパスの改善優先度が上がる。この人工入力の結果を、最適化対象がほぼないRuby Wasmへそのまま一般化しない。

## 改善候補

### 1. レジスタ検証の配列生成と命令再走査

[RegisterValidation](../lib/wardite/efflorescence/register_validation.rb) は型検査、Analysis、FlowGraph、ブロック構築、逆postorder、definite assignmentの順に処理する。[FlowGraph](../lib/wardite/efflorescence/optimizer.rb) は、EHを使わない関数にも命令ごとのnormal/exceptional/handler-stack配列を作る。さらに到達ノードでhandler stackを複製する。通常辺は多くが次の命令へのfallthroughなのに、命令単位で保持してから検証側でブロックへ集約している。

最初の候補はEHなし専用のブロックCFG。fallthroughを暗黙にし、例外辺・handler stackの配列を省く。型検査、branch target検査、未定義レジスタ拒否、到達可能なfallthroughの拒否は維持する。検証を省略する案ではない。

[Function#reads / Opcode.read_positions](../lib/wardite/efflorescence/ir.rb) も、各走査でoperand位置配列とレジスタ番号配列を作る。固定operand位置の共有、または配列を返さずレジスタを列挙するAPIを候補にする。definite assignmentはブロックを再処理するたびに全命令のread/writeを調べるため、ブロックのuse/defサマリー化も候補。ただしCALLの結果は正常辺にしか存在せず、catch辺は固有の定義を持つ点に注意する。

### 2. Wasmデコードの1バイト文字列と命令表現

[BinaryLoader.code_body](../lib/wardite/load.rb) と [LEB128](../lib/wardite/leb128.rb) は `read(1)` → `ord` を繰り返す。opcodeの解決にも3要素配列を返し、[Op.operand_of](../lib/wardite/instruction.rb) はoperand型配列を都度生成する。各命令はnamespace・symbol・operand配列・else/end位置の5要素配列になる。

段階的には `getbyte` またはbyte cursor、operand仕様の固定表、一時tupleの削減を試す。Spinelの手元のStringIO実装には `getbyte` / `readbyte` がある。ただし返り値のunboxingとEOF処理も測る必要がある。LEB128の幅超過、途中EOF、符号拡張の拒否条件を保つ。

feature確認の0.920秒は別の全命令・全operand走査で、MIR向けでも各operandがBlockかを調べる。この段階のCRuby割り当てはほぼゼロだったため、一時オブジェクト削減だけでは解決しない。デコード時にblock参照を集める、またはblock typeの解決を統合することで再走査を絞る余地がある。

長期的にはWasm命令配列を介さず、関数単位でデコードしてMIRへ流す経路も考えられる。stack VMと共有している構造化制御の情報、エラー位置、型・feature検査を整理する必要があり、最初の変更としては大きい。

### 3. 最適化器の全IRコピーを絞る

[Optimizer#optimize](../lib/wardite/efflorescence/optimizer.rb) がsemantic IRを丸ごとコピーし、続けて `Inlining#run` がcalleeのsnapshotとしてもう一度丸ごとコピーする。最適化対象外の関数にも両方のコピーが発生する。さらに `Inlining#expand_calls` は、展開対象のCALLがなくても全命令をコピーしてrewriteする。

まずcallee snapshotをeligibleな小関数だけに絞る、CALLも対象calleeもないcallerを早期にスキップする、という変更が考えられる。semantic IRをinspection用に保持する契約があるため、全関数を無条件で共有するとloweringや後続の書き換えが元IRへ漏れる。copy-on-writeまたは必要時の再生成は別途設計する。

[Function#copy](../lib/wardite/efflorescence/ir.rb) には、レジスタごとに `constant_registers.include?` を行う O(R×C) の走査もある。constant membershipのbitmap化、または単調に並んだconstant registerのcursorによるコピーが候補。既存順序を守ることを確認する必要がある。

### 4. 大きなi32関数のcopy propagation

[CopyPropagation#propagate](../lib/wardite/efflorescence/optimizer.rb) は各destinationの書き込みで `aliases.each_with_index` を全走査する。命令数I、レジスタ数Rに対して O(I×R)。block leaderごとにもR要素を初期化する。逆alias集合や世代番号による無効化、変更対象だけの追跡を候補にする。

またcopy pass内でAnalysisを最低4回、その後のbranch/superinstructionでも再作成する。変更のないrewriteを省く、dead-copy削除をuse-countのworklistにする、必要な情報だけ解析する、といった改善が考えられる。branch target修復とEH辺の扱いを維持する。

## 次の実装で確認すること

上記の短縮率は未実装の改善に対する保証ではない。例えば検証を半減できた場合のload全体の短縮上限は約18%、デコード＋feature確認を半減できた場合は約17%。最適化器全体をゼロにしてもこの大入力では約9%なので、個々の最適化パスだけに集中しない。

各変更はcold MIR生成時間、割り当て、ピークRSS、生成MIR/実行結果、ゲスト実行速度を別々に比較する。特にinlineの無効化や最適化coverageの縮小は、生成が速くても実行時間を悪化させ得る。検証変更には未定義read、到達不能コード、loop/backedge、複数join、CALL結果、EH payloadの既存拒否テストが必要。最終判断前にRuby 4.0.9のfixtureと別の大きなWasmでも再測定する。

## 再現手順と生データ

ビルド用ディレクトリは未作成のものを指定する。準備スクリプトは本番 `lib/` をコピーし、Prismのメソッド境界にタイマーを挿入する。`detail` は親子の詳細計測、`none` は本番ソースをそのままコピーする対照条件。workerはCRuby/Spinelの両方で動く。

```sh
ruby benchmark/prepare_mir_generation_profile.rb build/mir-generation-repro
spinel -I build/mir-generation-repro/lib --strict-require -O2 \
  build/mir-generation-repro/mir_generation_worker.rb \
  -o build/mir-generation-repro/worker
RUNS=3 WARMUPS=1 ruby benchmark/measure_mir_generation.rb \
  build/mir-generation-repro tmp/ruby.wasm examples/i32_bench.wasm > build/mir-generation-repro/results.json

ruby benchmark/prepare_mir_generation_profile.rb build/mir-generation-repro-detail detail
spinel -I build/mir-generation-repro-detail/lib --strict-require -O2 \
  build/mir-generation-repro-detail/mir_generation_worker.rb \
  -o build/mir-generation-repro-detail/worker
RUNTIMES=spinel RUNS=3 WARMUPS=1 ruby benchmark/measure_mir_generation.rb \
  build/mir-generation-repro-detail tmp/ruby.wasm > build/mir-generation-repro-detail/results.json

ruby benchmark/prepare_mir_generation_profile.rb build/mir-generation-repro-control none
spinel -I build/mir-generation-repro-control/lib --strict-require -O2 \
  build/mir-generation-repro-control/mir_generation_worker.rb \
  -o build/mir-generation-repro-control/worker
RUNTIMES=spinel RUNS=3 WARMUPS=1 VARIANTS=default,no-inline \
  ruby benchmark/measure_mir_generation.rb build/mir-generation-repro-control \
  tmp/ruby.wasm > build/mir-generation-repro-control/results.json

ruby benchmark/generate_mir_generation_fixtures.rb build/mir-generation-repro-fixtures
RUNS=3 WARMUPS=1 ruby benchmark/measure_mir_generation.rb \
  build/mir-generation-repro-detail build/mir-generation-repro-fixtures/*.wasm \
  > build/mir-generation-repro-detail/scaling.json

bundle exec ruby -Ilib benchmark/profile_mir_generation_allocations.rb \
  tmp/ruby.wasm build/mir-generation-repro/allocations.json
```

`tmp/ruby.wasm` はリポジトリに含めない外部fixture。上記SHA-256と一致する入力を指定する。別のWasmでも測定できるが、start sectionと未対応importがないことが条件になる。`RUNTIMES=cruby` ならnativeビルド不要。macOSで権限がある環境なら `RSS=1` で `/usr/bin/time -l` によるRSSも記録できる。

- [主計測](../benchmark/results/mir-generation-coarse.json)
- [Spinelの詳細計測](../benchmark/results/mir-generation-detail.json)
- [タイマーなし・inline無効化](../benchmark/results/mir-generation-control.json)
- [i32サイズ依存性](../benchmark/results/mir-generation-scaling.json)
- [CRuby割り当て・Vernier self samples](../benchmark/results/mir-generation-allocations.json)

計測コード: [準備](../benchmark/prepare_mir_generation_profile.rb)、[worker](../benchmark/mir_generation_worker.rb)、[反復実行](../benchmark/measure_mir_generation.rb)、[サイズ別fixture生成](../benchmark/generate_mir_generation_fixtures.rb)、[割り当て診断](../benchmark/profile_mir_generation_allocations.rb)。

## 計測コードの確認

- coarse/detail/controlのSpinel workerをビルド・実行した。CRubyとSpinelの関数数、semantic/optimized命令数、レジスタ数が、各fixture・設定の全sampleで一致することを確認した。
- 詳細タイマーを入れたライブラリでoptimizer・inlining・register initializationの既存テストを実行し、24 tests / 5,872 assertions、失敗0。メソッドの `source_location` もコピー側を指すことを確認した。
- 4種類のi32-chainをCRubyのEfflorescenceとWasmtimeで実行し、入力123に対する結果が `123 + N` と一致した。
- 計測スクリプトの構文、保存JSONの解析・sample数・IR統計、ドキュメントへのリンクを確認した。

## Spinelでの関数単位の並列生成（2026-11-19）

macOS arm64、Spinel `a2aa05227`、`make spinel` の既定オプションで、上記の Ruby 3.4.2 fixture（8,161 関数）を使用した。タグ `v1.3.0` と変更後の CLI を比較した。各条件で毎回新しいプロセスを起動し、MIR キャッシュを使わず、条件の順序を往復させてウォームアップ 1 回の後に 5 回測定した。全回で標準出力は `42`、終了コードは 0。

```sh
WARDITE_TRACE=1 WARDITE_MIR_WORKERS=8 SPINEL_WORKERS=8 \
  build/wardite -- tmp/ruby.wasm --disable-gems -e 'puts 6*7'
```

| 条件 | semantic MIR 生成 | モジュールロード全体 | プロセス起動から終了まで |
| --- | ---: | ---: | ---: |
| v1.3.0 | 1.310 s | 1.864 s | 2.469 s |
| 1 ワーカー | 1.505 s | 2.134 s | 2.777 s |
| 2 ワーカー | 0.827 s | 1.458 s | 2.101 s |
| 4 ワーカー | 0.457 s | 1.082 s | 1.723 s |
| 8 ワーカー | 0.394 s | 1.021 s | 1.666 s |
| 環境変数未指定 | 0.391 s | 1.029 s | 1.669 s |

値は中央値。タグ版の MIR 生成時間だけは、同じタグの `Translator#translate` に単調時計の計測を追加した別ビルドで測った。8 ワーカーではタグ版比で MIR 生成が 70%、プロセス全体が 33% 短縮した。変更後は Spinel のスレッド対応ランタイムをリンクするため、1 ワーカーでのプロセス全体はタグ版より 12% 遅かった。ゲストの実行時間が中心の `i32_mix.wat` の `call_mix(10000000, 123)` はタグ版 219.84 ms、変更後の既定設定 220.80 ms。同じ関数の反復 0 回では 3.67 ms から 4.24 ms になった（各 9 回の中央値）。

`ruby.wasm` の MIR2 ファイルはタグ版と 8 ワーカー版で 83,817,292 バイトすべてが一致した（SHA-256 `9e52cc9ec5e4c65dc725cf5128330f19670f9df0cc1030cdda4c5ea66c839c8a`）。Base64 の WASI モジュールでもタグ版と 1・2・4・8 ワーカー版の MIR2 ファイルが一致した。
