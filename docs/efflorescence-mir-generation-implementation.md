# キャッシュ前MIR生成の改修: 実装担当向け入口

2026-11-16。[性能調査](efflorescence-mir-generation-performance.md)に基づくADRと共通の検証条件。実装状況と計測結果は各ADRを参照。

| 調査の結論 | 実装仕様 | 主な決定 |
|---|---|---|
| 検証・デコードが大入力のload時間の約71% | [ADR 0014](adr/0014-efflorescence-mir-build-validation-and-decoding.md) | 非EHのブロックCFG、配列を作らないread参照、byte読み出し、デコード結果のfeature情報 |
| 最適化時間の約99%が2回の全IRコピー | [ADR 0015](adr/0015-efflorescence-selective-inline-snapshots.md) | 最初の独立コピーを維持して線形化、callee snapshotだけ選別、無変更callerのrewriteを回避 |
| 大きなi32関数のpropagateが超線形 | [ADR 0016（取り下げ）](adr/0016-efflorescence-generation-tagged-copy-propagation.md) | rootの更新世代とblock epochでaliasを遅延無効化する案 |

## 基準と実装範囲

- 基準の本体コードは `1de771dcf6024792e053aa2ed9214df3a9613d8f`。調査文書・`benchmark/*mir_generation*.rb`・`benchmark/results/mir-generation-*.json` は同じ調査で追加した成果物。別checkoutへ引き継ぐ場合はそれらも含める。
- 目的はキャッシュ前の生成を速くすること。実行命令、最適化の適用範囲・順序・予算、検証の受理/拒否条件を維持する。追加の最適化や命令削除を混ぜない。
- 既存CLI、`semantic_ir` / `optimized_ir` / `--mir-dump`、MIR2キャッシュ、snapshot、stack VMを保つ。
- semantic命令のPCは命令ordinal。`Lowerer` だけが幅4のflat offsetへ変換する。この区別を新しいCFG・rewriteでも守る。
- ADR 0013のレジスタ詰め直しはこのシリーズに含めない。先に実装されていれば基準を取り直し、同時にアルゴリズムを変更しない。

## 推奨する順序と分担

1. baselineを保存し、比較用のIR正規化と診断カウンターを用意する。
2. ADR 0015を実装する。変更範囲が小さく、semantic IRの所有関係を変えずに2回目の全コピーを除去できる。
3. ADR 0014をread API → 非EH検証 → byte読み出し → feature情報の順に実装する。各段階で計測する。

上の順序はレビューと原因切り分けを容易にするため。0014と0015にアルゴリズム上の依存はない。`ir.rb` と `optimizer.rb` が重なるので、並行した実装を無検証でまとめない。

各ADRの実装段階を個別コミットにする。コミット1行目を簡潔にし、詳細は必要最小限、`Co-authored-by: Codex <codex@openai.com>` を付ける。既存の未コミット成果物を取り消さない。

## 正しさの共通契約

成功したことや命令数の一致だけでは同値性の証拠にならない。テスト用にIRを次の値だけの構造へ正規化し、変更前後で比較する。循環するcalleeオブジェクトを直接JSON/Marshalに渡さない。

- IR: functionの順序、entryのkind・defined/host index・シグネチャ、hostのシグネチャ。
- Function: module index / pool index、引数・結果・local・全registerの型、初期値、constant register、feature flags、全命令のoperand。
- side table: dynamic callの引数・型・host/table index、memory siteのsourceとindex、throw payload、handlerのtag・payload・reference・target PC・handler depth。
- lowering後: bytecode、flat handler、call siteのcallee module indexとargument register。
- オブジェクトIDや実行時host callableのIDは比較対象外。floatは浮動小数点値へ戻さずbit carrierで比較する。

各最適化トグル（既定、`:all`、各featureの単独無効化）とprofilingあり/なしを同じ設定同士で比較する。invalid MIR/Wasmは受理/拒否、例外のクラス、原因の分類と位置を確認する。複数の誤りを持つ入力の「最初に検出する誤り」の順序だけは変更を記録してよい。新たな受理や既存正常入力の拒否は本シリーズの完了条件を満たさない。潜在バグ修正が必要なら別変更として扱う。

生成MIR2の内容・意味を変えないので `MIRCache::FORMAT_VERSION` / `CODE_VERSION` は上げない。上記正規化またはpayloadで差が出たら、バージョンを上げて通すのではなく原因を調べる。意図した意味変更へ方針転換する場合はADRを改訂し、別の変更として判断する。

## 検証コマンド

以下は実装PRでの完了条件。この設計文書の作成時に改修後の実行を確認したという意味ではない。

```sh
bundle exec rake test
bundle exec rake check
make spinel-test RUBY="bundle exec ruby"
bundle exec rake parity
WARDITE_SPINEL_BIN="$PWD/build/wardite" \
  bundle exec ruby scripts/verify_ruby_wasm.rb "$ruby_wasm_4_0_9"
```

型生成で `sig/generated/` が変われば実装に含める。Spinelは `-O2`、inline RBSと既定のオーバーフロー検査を維持する。Rubyだけの`Set`や多倍長整数のbitset、動的な`send`/monkey patchを本番の高速経路に導入しない。既存の32bit word bitsetを使う。nativeで表現できることは実際のコンパイルと実行で確かめる。

WasmtimeのEH対応不足、外部Wasm不在などで検証できなければ未検証項目として残す。小fixtureのみの成功で大入力・EH・nativeまで合格扱いしない。キャッシュのmiss→hit、eager/lazy restore、snapshot、inspection復元の既存テストも実行対象。

## 性能の比較方法と判定

[調査の再現手順](efflorescence-mir-generation-performance.md#再現手順と生データ)を使用する。各checkoutで新しい出力ディレクトリにworkerを生成する。生成済みディレクトリはソース変更に追随しない。変更前後で同じSpinelを使い、compileと計測を同時実行しない。

- まず変更前後を各warmup 1回、独立プロセス5回以上、before/afterの順序を交替して測る。既存driverは1つのsource directoryを測るので、比較時は外側のdriverで2つを交替する。結果にrevision・dirty diff・入力hash・コンパイラ版・flagsを残す。
- `none` workerのload全体を主指標にし、coarse/detailで原因を切り分ける。`no-inline` は診断用で、before/after比較は既定の最適化設定を変えない。
- Ruby 3.4.2 fixture（SHA-256 `1ac460e944a54c17529aa05e6cad4575aab6d3d2466745f935237f7a46351e98`）を再利用する。Ruby 4.0.9 fixtureは別hashとして追加する。入手できない場合はその評価を未完了として明記し、3.4.2の結果と混ぜない。
- 小i32、i64、float、memory、call、EHのfixtureを含める。巨大i32は既存generatorのN=256/512/1024/2048に加え、4096/8192を追加する。
- CRuby割り当て、native/CRubyピークRSSを別に測る。RSSを取れない環境では未測定と記載。GCやprofilingの費用をフェーズtimeに加算し直さない。
- メソッドの分割・名称変更では `prepare_mir_generation_profile.rb` とallocation profilerも更新する。特に `code_body` がadapterになったら実処理の `decode_body` を同じフェーズとして測る。消えた呼出しを未計測のまま「0秒」と報告しない。

**合格は構造的な削減と実測を両方示すこと。** 各ADRのカウンター条件を満たし、対象のphase中央値がbeforeより短くなることを示す。5%未満の時間差、またはばらつきに埋もれる差は10回以上へ増やす。改善が再現しなければ性能改善済みとはせず、設計と実装を見直す。

load全体・非対象fixture・ゲスト実行速度の中央値が5%超悪化した場合は追加測定し、再現する退行が残る段階は取り込まない。サブミリ秒fixtureは独立プロセスを十分増やし範囲も示す。5%は絶対的な統計保証ではなくレビュー開始の閾値。11.51秒など過去の絶対時間を合否に使わない。期待する短縮率は未実装の時点では約束しない。

## 実装PRの提出物

該当ADRの段階ごとのコード・回帰テスト・RBS、上記正規化の比較結果、before/afterの生データ、中央値・範囲・構造カウンター、未実施の条件、cache/guestへの影響を含める。ADRの状態は必要な検証が揃ってから更新する。設計から逸れた部分は理由と最終設計を追記し、次の実装者に未決定の選択を押し付けない。
