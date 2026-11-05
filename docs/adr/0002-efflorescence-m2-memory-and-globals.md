# ADR 0002: Efflorescence M2のメモリとグローバル変数

- 状態: 採用。M2a〜M2fを実装・検証済み。[実装・検証・性能記録](../efflorescence-m2.md)を参照。
- 調査基準: main `1563ac6`（M1実装のmerge後）
- 前提: [M0対応範囲](../efflorescence-coverage-ja.md)、[M1実装記録](../efflorescence-m1.md)、[ADR 0001](0001-efflorescence-m1-control-and-eh.md)
- 対象読者: M2を内部フェーズに分けて実装する担当者

## 決定と対象範囲

M2ではi32のメモリアクセス、i32のglobal、memory管理の15命令を実装する。
Storeを状態の唯一の保持元とし、Efflorescenceの整数レジスタと共有Storeの境界を明示する。
M1のEH・参照bank・明示的Frameを維持する。PR #21の方針に従い実行はflatに統一する。
意味MIRは検証・変換・表示用に保持し、flatの切り替えフラグは追加しない。

| 分類 | 命令 |
|---|---|
| load（5） | i32.load、i32.load8_s/u、i32.load16_s/u |
| store（3） | i32.store、i32.store8、i32.store16 |
| global（2） | global.get、global.set |
| memory（5） | memory.size、memory.grow、memory.init、memory.copy、memory.fill |

memory 0、32bitアドレス、非shared memoryを対象とする。i64/f32/f64のアクセスはM4/M5。
import・WASI・call_indirectはM3。multi-memory、memory64、threads/atomic、data.dropは追加しない。
非i32 globalへのアクセス、globalへのexnref保存も拒否する。
使わない非i32 global宣言については共有Storeの既存挙動を維持し、読み書き命令を型で拒否する。
既存のmemory/global export、active data初期化、startは共有の処理を利用する。

## 実装方針

### 状態と初期化

Frameにmemory/globalの複製を持たせない。VMからinstance.storeを参照する。
同じinstanceへの複数callでは更新を保持し、別instanceとは分離する。
Memory.dataはbinary String、currentはページ数。常にbytesize = current * 65536を保つ。
文字数を用いずbytesize/getbyte/setbyte等のバイトAPIを使う。
memory.growがStringを置き換える可能性があるので、古いdata参照をcallやgrowを越えてキャッシュしない。

global.getは共有Global.valueのI32から正規化整数を読み、新しいレジスタ値として保持する。
global.setは型とmutableを変換時に確認し、共有Global.valueをI32で更新する。
当初はこの境界でboxingを許容する。global専用のキャッシュによる二重管理は行わない。
後続のglobal.setやcalleeによる更新が、既に読んだglobal.getの結果を変えてはいけない。

### 範囲チェックとtrap

アドレスレジスタはunsigned i32。effective address = address + static offsetを十分な整数幅で計算し、32bitへwrapしない。
範囲チェックの共通helperを設け、start <= sizeかつlength <= size - startを確認してからアクセスする。
0長でもstart > sizeは失敗し、start == sizeは許容する。静的offset、アクセス幅、alignmentを別々に扱う。
alignmentはヒントであり未整列アクセスを許す。ただし不正なalignment即値をロード時に拒否する。

storeとbulk命令は全範囲を検査してから書き込み、trap時はその命令による部分更新を残さない。
RubyのStringの範囲外拡張・短いslice・負の添字に意味を委ねない。
M1と同じtrap系統のエラーを用い、Wasm exceptionへ変換しない。catch_allを通過しない。
trapやthrowより前に完了した更新は取り消さない。EHの巻き戻しはStoreのrollbackではない。

### load/store

little endianを明示し、符号付き狭幅loadは符号拡張後に0xffffffffで正規化する。
store8/store16は下位8/16bitだけを書き込む。
整数bankのまま処理し、既存stack Evaluatorを呼び出さない。
byte処理は共通helperに分けてよいが、毎回Wasm値を生成する実装は避ける。

### size/grow

sizeは現在のページ数。grow成功は旧ページ数、失敗はレジスタ上0xffffffff。
最大値は宣言maxとmemory32上限65536ページの小さい方。delta=0も検証する。
上限検査・新しいbufferの準備後にdata/currentを一括更新し、失敗時は両方を維持する。
新領域はゼロ初期化する。巨大な実割当をテストせず、割当失敗を注入できる境界を設ける。

既存Memory#growに必要なチェックが不足する場合は、Efflorescence用のchecked helperから呼ぶか、共有helperを追加する。
共有既存APIを修正する場合は旧VMの回帰テストも同じフェーズへ含める。
割当失敗だけを狭い境界で処理し、StandardError全体やRubyの実装バグをgrow失敗へ丸めない。
Spinelで割当失敗を回収できない場合はその制約を記録し、プロセスOOM回復を未検証のまま保証しない。

### bulk memoryとdata segment

copyは重複領域を許す。初回実装は範囲検査後にsourceの独立したbyte列を作ってからdestinationへ書く。
fillはvalue & 0xffを用いる。initはdata indexとmemory indexを検査し、segmentからmemoryへコピーする。
source/destinationを両方検査した後に更新する。0長・境界・重複を共通テストにする。

memory.init用の実行時data segment状態をinstance単位に持つ。
passive segmentは内容を保持し、active segmentは共有Storeの初期化後、実行時initから見た長さを0とする。
構文上のdata sectionの文字列を常に再利用可能なsourceとして扱わない。
data.drop自体は未対応のままとし、遭遇した場合は明示拒否する。
デコーダーのdata countとdata indexの検証を確認し、不足分は追加する。

### MIRと最適化

load/storeはopcode、dstまたはvalue、address、offsetの4整数で表せる。
globalとsize/growも既存4整数幅で表す。bulk命令はFunctionのMemorySite表を用意し、3つのsource registerとsegment/memory indexを保持する。
この表は既存ThrowSite同様にdeep copy・read解析・レジスタ置換・Inspectionの対象とする。
staticな表だけに値を置き、実行中の値をFunctionへ書き戻さない。

Opcode.read_positions/destinationの範囲判定を見直し、storeをdestinationありと誤認しない。
may_trapにメモリアクセスを加えるが、may_throwには加えない。例外CFGへtrap edgeを足さない。
状態の読み書きを明示し、未使用loadでもtrapを除去しない。callをまたぐload/global.getの再利用は行わない。

初回M2ではmemory/global命令を持つ関数にuses_store相当の印を付ける。
copy/immediate/branch/superinstructionはその関数では保守的に適用しない。
inliningは対象関数内への展開と、その関数のcalleeとしての展開を両方止める。
EH関数のM1の除外規則も維持する。通常i32関数の既存最適化は継続する。
flat、profiling、frames、RegisterValidationはM2関数でも利用できることを必須とする。
最適化の解禁やload/store fusionはM2の完成後、測定と別のレビューを経て行う。

### ロード時の拒否

memory不在、不正なmemory/global/data index、immutable global.set、型不一致を変換時に拒否する。
未export関数・到達不能コードでも即値と対応範囲を確認する。
memory 0以外の即値、shared/memory64等を旧形式として誤読しないよう、共有limitsデコードも確認する。
構文検証、未対応機能、実行時trapを区別し、外部wasm-toolsのvalidateだけに依存しない。

## 内部フェーズとコミット

**内部フェーズごとにコミットを作る。** 各フェーズの実装・テスト・必要な生成RBS・文書更新を揃え、検証後にコミットしてから次へ進む。
全フェーズを一つのコミットにまとめない。大きなフェーズは複数コミットに分割してよい。
各コミットはテスト可能な状態にし、未完成命令は明示的に拒否する。
コミットメッセージは簡潔にし、`Co-authored-by: Codex <codex@openai.com>`を付ける。

| フェーズ | 作業 | 完了条件 |
|---|---|---|
| M2a | feature/type/index検査、checked byte helper、MemorySite、uses_store、Opcode情報 | 不正入力・範囲境界・IR copy/read解析のテストが通る |
| M2b | i32 global.get/set | mutable/immutable、snapshot、call越し更新、instance分離が成立 |
| M2c | 8種類のi32 load/store | 全幅・符号・未整列・offset・境界trapをflat実行で確認 |
| M2d | memory.size/grow | 成功・上限・0・失敗時の状態維持・grow後アクセスを確認 |
| M2e | init/copy/fill、実行時segment状態 | passive/active、0長、重複、全範囲事前検査が成立 |
| M2f | EH・call・start・profiling統合、性能と対応表更新 | 下記の受け入れ条件を満たし、結果を文書化 |

各フェーズでflat実行を実装する。M2fまでテストを先送りしない。

## 受け入れ条件とテスト

- 全load/store幅で最終有効アドレス・1byte超過、offset加算が2^32を越えるケース、負数相当i32のアドレス、未整列アクセス。
- 狭幅の符号境界とstore切り詰め。失敗store後にmemory内容・bytesize・currentが不変。
- global.getの結果保持後にglobal.set、calleeによるglobal更新、再帰、公開callの反復、別instanceの独立性。
- grow前の内容、追加領域のゼロ、maxなし/あり、delta=0、失敗後の状態、growしたcalleeから戻った後のload。
- copyの前方/後方重複、同一領域、sourceのみ/destinationのみの範囲外、0長の境界。
- fill値0/255/256/0xffffffff。initの空segment、passive再利用、active初期化済みsegmentの実行時扱い。
- bulk失敗前後のメモリsnapshot。sourceの不足でStringが縮まないこと。
- store/global.set後にthrowしてcatch、更新が残ること。memory trapはcatch_allを通らないこと。
- trap/未捕捉例外後の再call、フレーム再利用、startでのmemory/global利用。
- 未使用loadのtrap、call前後の状態変化、最適化設定ごとの結果一致、元IRの表が書き換わらないこと。

通常ケースは旧VM・Efflorescenceで独立instanceを作り、戻り値に加えてmemory全体・current・global値を比較する。
M0で見つかった旧VMの境界store/copy/fillの誤動作を正解にしない。これらは独立期待値と参照エンジンを用いる。
参照エンジンはM1で使ったWasmtimeを候補とし、実装時にバージョンとEHオプションを確認する。
外部比較にはgrowの実リソース不足など環境依存の結果を要求せず、確定的な上限失敗は比較する。

CRuby/Spinelのdefault、all無効、framesのみ無効、profiling有効を確認する。
M1のEHテストと従来のi32テストも通す。実行コマンドは以下を基準とする。

```sh
bundle exec rake test
bundle exec rake check
make spinel-test RUBY="bundle exec ruby"
```

Spinelの省略を成功として記録しない。checkによる生成RBS差分を含めて確認する。
M1のi32_mix/call arityベンチマークで非memory経路の退行を確認する。
M2では配列走査・copy/fill・global更新の小さなベンチマークを追加し、checksum、ロード時間、実行時間を分けて記録する。
性能改善率は完了条件にしない。再現する退行は説明・対処してから閉じる。

## 変更箇所

| 箇所 | 変更内容 |
|---|---|
| lib/wardite/load.rb、instruction.rb | memory即値、limits、data count等の検査 |
| lib/wardite.rb | Store/Memory/Globalの接続。共有変更には旧VM回帰テスト |
| efflorescence/translator.rb | 型・即値検査、状態アクセスMIR生成 |
| efflorescence/ir.rb | Opcode情報、MemorySite、uses_store、copy/参照列挙 |
| efflorescence/optimizer.rb | 安全な除外、flat lowering、表の維持 |
| efflorescence/vm.rb | flat dispatch、checked memory操作、実行時segment状態 |
| efflorescence/register_validation.rb、inspection.rb | source/destination検証、表の表示とprofiling |
| test、sig/generated、docs | 正常系・境界・拒否・統合テスト、生成型、実装記録 |

Efflorescenceのパスはlib/warditeからの相対。
共有メモリの不具合を全面修正することはM2の前提にしないが、M2用helperを共用するときは影響を検証する。
範囲チェックの省略、旧VMへのfallback、Ruby例外の一括捕捉でテストを通す実装は採らない。
難しい設計問題に突き当たった場合は、最小再現と検討結果を残し、AGENTS.mdに従ってAstraへの切り替えを提案する。

## 根拠と参照

- [WebAssembly実行規則](https://webassembly.github.io/spec/core/exec/instructions.html): memory/global命令の意味。実装時に参照revisionを記録する。
- [M0の実行確認](../efflorescence-coverage-ja.md): 旧VMを無条件に正解にできないケース。
- [M1実装記録](../efflorescence-m1.md): EH、bank、CFG、最適化除外と実行構成。

MemorySite、uses_store、helperの分割、内部フェーズはWardite向けの設計判断であり、仕様の要求とは区別する。
