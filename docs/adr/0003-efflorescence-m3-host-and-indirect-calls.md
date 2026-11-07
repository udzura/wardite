# ADR 0003: Efflorescence M3のホスト呼び出しと間接呼び出し

- 状態: 採用。実装と検証結果は [M3実装記録](../efflorescence-m3.md) を参照。
- 日付: 2026-11-07
- 調査基準: main `80dd56d`（M2とbulk転送改善のmerge後）
- 前提: [M1実装](../efflorescence-m1.md)、[M2実装](../efflorescence-m2.md)、[M0調査](../efflorescence-coverage-ja.md)

## 決定と到達点

M3で関数import、ホスト関数呼び出し、call_indirectをEfflorescenceへ追加する。
共有Store・ExternalFunction・WasmModule/HashModuleのインターフェースを利用し、旧Runtimeへfallbackしない。
M2の現状に合わせ、実行はflatのみ。意味MIRは変換・検証・表示に残す。semantic interpreterやflat無効化オプションを復活させない。

| 項目 | M3の範囲 |
|---|---|
| 関数型 | i32引数0個以上、voidまたは単一i32結果 |
| 直接call | defined/imported関数の両方 |
| 間接call | table 0のfuncref、defined/imported関数の両方 |
| ホストABI | callable[Store, Array[wasmValue]]。引数はI32へboxing |
| 公開API | imported関数の再exportもcall/call_unboxedから呼べる |
| 初期化 | 全関数・型・table/elementの準備後にstartを実行 |
| WASI | CRubyでfd_writeの縦通しを必須。i32シグネチャの既存関数へ接続 |
| Spinel | WASIなしのホスト関数と間接callを検証 |

memory/table/global import、table操作命令、call_ref、tail call、非i32関数型、複数結果、外部instanceのWasm関数直接リンクは対象外。
WASI全体の対応完了は宣言しない。i64引数・結果のWASI関数はM4以降。
M1で将来候補として挙げたtag import/export・ホスト例外のWasm EH化は、今回のM3から分離し後続ADRへ保留する。
これは新しいABIとtag共有の設計を混ぜず、呼び出し境界を先に成立させるためのスコープ決定である。

## 現実装から変更する前提

Translatorはimportを一律拒否し、IR.functionsの添字をWasm関数indexと同一視している。
CallSiteは必ず内部Functionを保持し、そのindexをpool_indexにも使う。
Lowerer、VMの入口、pool生成、Inlining、Inspectionにもこの前提がある。import拒否の削除だけでは動かない。
既存Runtimeのcall_indirectは型をoverrideしたcloneを作るため、正しい型検査の手本として流用しない。

## 実装方針

### 1. Wasm indexと実装側indexを分離する

IR.functionsはdefined関数だけの密な配列として維持し、追加のFunctionEntry配列をWasm関数indexで引ける形にする。
FunctionEntryはkind、引数/結果型、defined_indexまたはhost_indexを持つ。不使用側のindexは-1とする。
Function.indexは引き続きWasm indexとし、FramePool用のdense indexを別属性で持たせる。
host descriptorはExternalFunctionと検証済み型を保持する。内部Functionとhostのunionをi32のdispatchに持ち込まない。

function_at(wasm_index)はentryを解決し、definedでなければ明示エラーにする。
全entryを先に作ってからdefined関数を変換し、前方callと相互再帰を可能にする。
Store.funcsの順序（importが先、definedが後）は変えない。

IR.copyはentry/descriptorの構造をコピーし、Function参照をコピー前のIRへ残さない。
StoreのExternalFunction/callable自体は共有してよいが、実行中の引数・戻り値・FrameはIRへ保持しない。
全 `.functions[index]`、function_at、pool_indexの利用箇所を棚卸しし、意味を明示する。

### 2. importの検査とリンク

共有importデコーダーはkind=0だけを関数として扱う。非対応kindをsig_indexとして誤読しない。
InstanceとTranslatorの一律拒否を、kind・型・対象module/nameの検査へ置き換える。
未使用importも型・リンクを確認し、全importの解決が終わるまでstartを呼ばない。
未export関数・到達不能コードの不正call indexや未対応型も拒否する。

既存Store生成がfunction/code sectionの存在を前提にしている点を確認し、import-only moduleとその再exportも扱う。
リンク順は「デコード・機能検査→Store/型/element準備→全entryとMIR/flat構築→start」。
ホストcallableを探索するだけで実行しない。欠けたmodule/nameはリンク時に失敗させる。
共有変更は旧VMのimport/startテストも通す。

### 3. ホストABIを一箇所に集約する

invoke_host(host_index, integer_arguments, store)相当の共通helperを設ける。
引数は各i32値をI32へboxingした新しい配列で渡す。Frame.registersそのものをホストへ渡さない。
内部defined callは引き続きunboxedのまま。

| 戻り値型 | 受理する値 | 処理 |
|---|---|---|
| void | nil | destinationへ書かない |
| i32 | IntegerまたはWardite::I32 | unsigned 32bitへ正規化して書く |
| その他/不一致 | Float、配列、i32結果にnil等 | host ABIエラーとして失敗 |

voidに非nilが返る場合もABIエラーとする。型不一致を未初期化の0で補わない。
callableの実行は一度だけ。エラー時に再試行しない。
共有Storeのmemory/global更新はその場で可視となり、後続trapでrollbackしない。
memory.growを行うホストから戻った後はStoreから最新dataを読む。

public call/call_unboxedも同じentry解決とABIを使う。imported exportの正常結果はcallでだけboxingする。
引数検査は既存のi32 APIに揃え、startの型は引数なし・結果なしを要求する。

### 4. MIRとflat命令

内部直接CALLは既存形式と単一引数fast pathを維持する。
新しくCALL_HOST、CALL_INDIRECTを設け、4整数幅を維持する。

| MIR案 | オペランド | side table |
|---|---|---|
| CALL_HOST | dst, site_id, 予約0 | host_indexとargument register列 |
| CALL_INDIRECT | dst, site_id, selector_register | expected型、table index、argument register列 |

dst=-1はvoid。side tableの全argumentをread解析・レジスタ置換・deep copy・Inspection・profilingへ含める。
selectorはi32として読む。call_indirectのWasm operand stackからはselectorを先にpopし、その後に引数列を取り出して順序を復元する。
検証時に引数型・個数・destination型を確認する。
内部CALLのcallee解決ではentryのdefined_indexからpoolを選ぶ。hostにFramePoolを割り当てない。

### 5. call_indirectの実行

1. selectorをunsigned i32として読み、table 0の現在のrefsから対象を引く。
2. 範囲外、nullをそれぞれtrapにする。負のRuby添字を許さない。
3. 実対象の引数型列・結果型列をexpected型と比較する。型indexの数値の一致では判断しない。
4. 不一致ならtrapし、calleeやホストを実行しない。
5. definedなら既存Frame転送へ、importedならinvoke_hostへ進む。

funcref tableはimported関数も格納できる設計にする。既存の「ExternalFunctionならexternref」という判定をEfflorescenceへ持ち込まない。
型のoverrideやcloneで不一致を隠さない。tableを変換時のcalleeへ固定しない。
共有element初期化がStore.funcsの実オブジェクトを格納することを確認し、そのidentityからentryへ解決する対応表を構築する。
ホストが同じinstance内の別の既知関数へrefsを変更した場合も次のcallで反映する。
未知の関数オブジェクトを直接挿入した場合は明示エラーとし、別instanceへ暗黙リンクしない。

### 6. 再入とEHの境界

各公開呼び出しは独立したframes/poolsと実行コンテキストを持つ。Storeだけを共有する。
ホストが同じVMの公開callへ再入し、戻った後に元のWasm実行を継続できることを必須にする。
現在VMのmetrics等の可変実行状態も確認し、ローカルなExecutionContextへ移すかpush/restoreする。
再入のensureが外側のFrameやhandlerを解放してはならない。新コンテキストは内部defined callごとには作らない。

Wasm同士の間接callはM1と同様にmay_throwとして例外CFGへ接続する。
例外edgeにはcall直前の定義とcatch payloadだけを渡し、正常結果dstの定義を流さない。
型不一致/null/out-of-rangeはtrapでありcatch_allを通らない。

CALL_HOSTからのRubyエラーはWasm例外に変換せず、そのまま公開境界へ伝播する。
再入したWasmが未捕捉例外をRubyへ返した場合も、外側Wasmのcatchへ自動接続しない。
ホストが自分で捕捉して正常値を返すことは許す。ホストからの例外注入APIは後続ADR。
SystemExitを含めensureで自分のコンテキストだけを解放し、再試行・rollbackしない。

### 7. 最適化と計測

host/indirect命令を持つ関数にuses_dynamic_calls相当の属性を付ける。
初期実装ではその関数の既存local passと双方向inliningを保守的に止める。
M1のuses_eh、M2のuses_storeの除外も維持する。内部直接callだけの既存最適化は継続する。
CALL_HOSTは副作用あり、CALL_INDIRECTは副作用・may_trap・may_throwあり。CALL_HOSTのRuby例外にWasm handler edgeを作らない。
未使用結果でもcallを消さない。ホストの副作用やtable変更をまたぐ値のキャッシュをしない。

profilingではhost呼び出し数・間接呼び出し数と内部Frame生成数を区別する。
MetricsのCALLだけを数える前提を更新し、二重計数を避ける。再入時の計測範囲を「各公開call単位」として記録する。

### 8. WASIとSpinel

CRubyで既存fd_writeサンプルをEfflorescence実行し、stdout、errno、nwrittenのメモリを検証する。
WASIのiovecが共有memoryを参照することを確認する。WASIを使わない通常importでWASIをロードしない。
既存proc_exitはRubyのexitを呼ぶため、テストは子プロセスで行い、終了codeを確認する。test runner本体を終了させない。
WASI全体の改修や終了API変更はこのADRでは行わない。

Spinelの共有ローダーによるWASI拒否は維持する。
ホストABIは小さなWasmModule実装から先に検証し、HashModule/callableも対応可能な形でテストする。
Spinelで既存callableインターフェースがコンパイルできなければ最小再現を取り、型や呼び出し方法を局所的に修正する。
Spinelテストを省略してM3完了とはしない。

## 内部フェーズとコミット

**内部フェーズごとにコミットを作る。** 実装・テスト・必要な生成RBSを揃えて検証し、コミットしてから次へ進む。
全フェーズを最後に一つにまとめない。大きいフェーズは複数コミットに分割してよい。
各コミットで既存機能が動き、未完成の新機能は明示拒否する状態を保つ。
メッセージは簡潔にし、`Co-authored-by: Codex <codex@openai.com>`を付ける。

| フェーズ | 作業 | 完了条件 |
|---|---|---|
| M3a | FunctionEntry、dense pool index、IR copy/lookupの移行 | importなしの全既存ケースと性能基準が維持される |
| M3b | importリンク、host ABI、直接CALL_HOST、再export/start | 0/1/多引数、void/i32、import-only、型不一致とリンク失敗を確認 |
| M3c | table/element接続、CALL_INDIRECT、実対象型検査 | defined/imported双方、null/範囲/型trap、重複型定義を確認 |
| M3d | 再入コンテキスト、EH境界、例外後の解放 | 再帰・再入・hostエラー・間接throw・再callが成立 |
| M3e | CRuby WASIとSpinel host統合 | fd_write、子プロセスproc_exit、Spinelの通常host callが成立 |
| M3f | profiling・外部比較・性能・文書 | 下記受け入れ条件を満たして実装記録を追加 |

M3bから自分のコンテキストの確実な解放を実装し、M3dまで例外処理を先送りしない。
M3dは再入とEHを含む組合せ検証の完成段階とする。

## 受け入れテスト

- 複数importの後にdefined関数を置き、call・export・start・elementすべてでindexずれがない。
- importだけのmoduleの再export、importとdefinedの前方/相互参照、欠けたmodule/name、未使用の未対応import。
- host引数0/1/複数の順序、Integer/I32結果の正規化、void、誤ったnil/Float/配列、callableが一度だけ実行される。
- hostが引数配列を保持・変更してもFrame.registersを破壊しない。
- hostによるglobal更新、memory書き込み/grow、その後のWasm読み出し、別instanceの分離。
- 間接callのdefined/imported、同一構造で別type index、引数/結果の不一致、null、table境界、0xffffffff。
- 間接call直前の引数評価の副作用は残り、型trap時にはcalleeの副作用が起きない。
- table内の既知関数の変更を次回呼び出しへ反映。未知関数の挿入は明示失敗。
- 間接callでthrowするcalleeをcallerのcatchが捕捉。正常結果未定義の負のMIR検査。
- hostのStandardError、再入内の未捕捉Wasm例外、SystemExitをWasm catch_allが捕捉しない。
- hostが同一VMへ再入し正常復帰/失敗を捕捉した後、外側のlocal/handler/PCとmetricsが壊れない。
- エラー前に完了したStore更新は残る。エラー後の公開callが正常に実行できる。
- profilingあり/なし、all無効、frames無効、既定で結果とhostログが一致。元IRのside tableが変更されない。

通常host契約はspy callableと独立期待値で検証する。旧VMの間接call結果を無条件の正解にしない。
Wasm内の間接call・型trap・EHはM1/M2で使った参照エンジンで比較し、実装時のversion/optionsを記録する。
異なるエンジンの任意Ruby callbackの比較は求めない。WASIはstdout・errno・memory等の観測可能な結果を確認する。
parse/validateは実行比較の代替ではない。

```sh
bundle exec rake test
bundle exec rake check
make spinel-test RUBY="bundle exec ruby"
```

共有ローダー/Storeの変更には旧VM回帰を含める。Spinel省略を成功扱いしない。
既存i32_mix/call arityを実装前後で測定し、checksum、ロード時間、実行時間を分ける。
新規benchは直接内部/直接host/間接内部/間接hostを分け、boxingとdispatchを混同しない。
EHなし・importなしの内部call fast pathの再現する退行を放置しない。M3の必須条件は対応と正しさであり、高速化率ではない。

## 変更箇所と再検討条件

| 箇所 | 主な変更 |
|---|---|
| lib/wardite/load.rb、lib/wardite.rb | import kind、feature check、Store/Exports/element、startの順序 |
| lib/wardite/wasm_module.rb | 既存host契約の維持。Spinelで必要な局所調整 |
| efflorescence/ir.rb | FunctionEntry、host/indirect site、pool index、copyとread解析 |
| efflorescence/translator.rb | import解決、callの振り分け、型とstackの検査 |
| efflorescence/optimizer.rb | lowering、callee lookup、pass除外、IR再配置 |
| efflorescence/vm.rb | entry dispatch、host adapter、間接解決、再入コンテキスト |
| efflorescence/register_validation.rb、inspection.rb | 新callのread/write/例外edge、表示、計測 |
| test、sig/generated、docs | ABI・拒否・再入・WASI・Spinel、型生成、実装結果 |

Efflorescenceのパスはlib/warditeからの相対。
具体名は実装時に変えてよいが、index分離、型検査、再入、EH境界を省略しない。
union型を導入してSpinelの内部call性能が大きく落ちる場合はdispatch構造を再検討する。
ホスト例外の自動EH化やtag共有が必要になった場合は本ADRの範囲を黙って拡張せず、別ADRを作る。
Sol/Lunaで難しい設計問題に突き当たったら最小再現・計測を残し、AGENTS.mdに従いAstraへの切り替えを提案する。
