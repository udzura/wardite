# ADR 0001: Efflorescence M1の制御構造と新形式EH

- 状態: 採用・M1a〜M1d実装済み。[実装・検証・性能記録](../efflorescence-m1.md)を参照。
- 日付: 2026-11-05
- 調査基準: `5534486`
- 対象読者: M1を分割して実装する担当者・レビュー担当者
- 前提: [M0の命令対応調査](../efflorescence-coverage-ja.md)

## 背景と決定

M1で既存VMのi32・制御命令との対応を揃え、追加でEfflorescenceだけに新形式EHの限定対応を導入する。
旧VMにはEHの実行処理を追加しない。共有ローダーは拡張し、旧VMでは新機能を明示的に拒否する。
旧形式の `try/catch/rethrow/delegate` は実装しない。

現状はi32の整数レジスタ、単一結果の制御構造、通常の分岐だけを扱う解析を前提にしている。
EHをdispatchに足すだけでは、例外経路で未定義レジスタを読んだり、再利用フレームの値を誤って参照したりする。
本ADRでは、実装順、値表現、例外の伝播、最適化の制約、完了条件を先に固定する。

M1はM1a〜M1dの全段階を完了して閉じる。途中の実装は部分対応と明記する。
以下のクラス・MIR名は提案名であり、名前の変更は許容する。意味・不変条件を変える場合はADRを更新する。

## 対応範囲

| 項目 | M1完了時 |
|---|---|
| 既存VMとの同等対応 | M0のM1欄の28命令。既存21命令の動作も維持 |
| 新形式EH | `try_table`, `throw`, `throw_ref` と4種類のcatch節 |
| tag | モジュール内定義。payloadは0個以上のi32。結果型は空 |
| 関数 | i32引数、voidまたはi32結果。直接call、再帰、相互再帰 |
| 例外参照 | nullable `exnref`のローカル・一時値・分岐結果、local.get/set/tee/drop |
| block signature | void、単一型、型インデックス。引数は空、結果はi32/exnrefの列 |
| loop | 引数なし。結果列を許すが、先頭への分岐で渡す値は0個 |
| 公開API | 既存i32 APIを維持。未捕捉Wasm例外を専用Rubyエラーとして返す |
| 実行環境 | CRubyとSpinel。semantic/flat、frames有効/無効の両方 |

M1ではtag import/export、ホスト例外、間接call、他の数値型、関数の複数結果、block/loop引数、参照型の関数引数・結果、参照のglobal/table格納、GC型階層を追加しない。
これらは正しいバイナリでも未対応として拒否する。tag/ホスト連携はM3、数値型のpayloadはM4/M5で拡張する。
`ref.null` や参照比較、typed selectもこのADRの追加範囲外。null再送出は初期値nullのexnrefローカルで検証できる。
M1aのuntyped `select` はi32に限定し、参照型へ流用しない。

複数のblock結果はEHのpayloadと例外参照を渡すために必要になる。これはM0時点の範囲を意図的に広げる変更であり、関数のmulti-value対応完了を意味しない。
非nullable参照型の宣言は拒否し、catchで得る例外参照は内部ではnullable exnrefの格納先へ安全に保持する。subtyping全体は導入しない。

## 実装上の決定

### 1. デコードとエンジンの機能判定を分ける

共有側にTagSection、tag型、catch節、block signatureの表現を加える。
blocktypeを現在の1バイト読みから、単一型・void・符号付き33bitの型インデックスを区別する読み込みへ変更する。
型インデックスは型セクションへ解決し、引数・結果を取り違えない。既存Blockの意味を曖昧に変更せず、明示的なsignatureを持たせる。

`try_table` を構造化制御の開始としてendの対応付けに含める。catch節はヘッダーのデータとして読み、独立した旧形式catch命令として解釈しない。
catchラベルはtry_table本体用のラベルをpushする**前**の外側のラベル環境で解決する。depth=0のケースを必ず検証する。
本体中の通常brはtry_table自身のラベルを含む環境で解決する。

機能判定はStore、Exports、start実行より前に行う。旧VMがEH・exnref・今回追加するblock形式を誤実行しないようにする。
ただし従来から動いていた通常の数値型blockを一律拒否しない。検出対象の機能を明示する。
import/exportのtag kindは既存の関数import等に誤解釈せず、M1では未対応として拒否する。
到達不能コード・未export関数内の未対応機能も拒否する現方針を維持する。

不正なtag index、型index、catch種別、ラベルdepth、payload/label型不一致、壊れたLEB128、切れた入力はロード・変換時のエラーにする。
共有ローダー全体の完全なWasm validator化は求めないが、今回追加する構造の検査を外部ツール任せにしない。

### 2. 整数レジスタと例外参照を分離する

`Frame#registers: Array[Integer]` と既存i32演算の直接アクセスを維持する。
Functionに仮想レジスタごとの型を持たせ、Frameに `exception_registers: Array[ExceptionValue?]` を追加する。
番号体系は共通とし、exnrefの仮想レジスタ番号を参照配列の添字にも使う。型は変換・検証時に決定し、i32演算中にunion型を判別しない。
参照を使わない関数は参照配列を空にできる。整数側のexnref用位置は未使用の0でよい。

参照のコピーは専用 `COPY_REF`。抽象スタック・スナップショット・合流・local.teeも型に応じてCOPY/COPY_REFを選ぶ。
`ExceptionValue` はtagの同一性とpayloadのコピーを保持する不変の値として扱う。throw_refはその値を再利用する。
tagはインスタンスごとに生成する識別値であり、シグネチャが同じでも別tagを同一視しない。
整数の疑似ポインタや、呼び出し終了まで全例外を蓄積するarenaは導入しない。

フレームをpoolへ返す際に参照配列とhandler状態をクリアし、次回の再利用時にもexnrefローカルのnullを保証する。
これは定義前参照の防止とは別に、不要な例外を保持し続けないための処理である。
例外を伝播中はVMのローカル変数で保持してからフレームを解放する。解放後の配列をpayloadとして参照しない。

共有WasmFunctionは現在、生成時にboxed default_localsを作る。この経路も変更対象である。
旧VM用default_localsを必要時に構築する形に分離し、Efflorescenceでは型メタデータから独自の初期値を作る。
共有wasmValue全体へ便宜的なnilを追加する方法は採らない。旧VMでは前段の機能判定でexnrefを拒否する。

### 3. 制御の合流を値の列として扱う

Translator::Controlの単一result_registerをresult_types/result_registersの列へ変える。
ラベルの分岐引数はblock/if/try_tableでは結果列、loopでは引数列（M1では空）とする。
関数結果は従来どおり最大1個。

複数値の転送はparallel copyとして扱う。最初は全sourceを同型の一時レジスタへ保存してからdestinationへコピーし、循環やaliasを壊さない。
条件分岐の転送とhandler解除はtaken edgeだけで行う。br_ifのfallthroughでは値の列をスタックに残す。
ifは入口の抽象スタック・到達可能性を保存し、elseで復元する。片側return/throw、両側非到達、elseなしを分けて合流する。

`select` はM1aではCOPYと条件分岐へ展開する。両operandの計算は既に実行済みであり、短絡評価へ変更しない。
`br_table` はi32.eqと条件分岐の列＋defaultへ展開する。targetごとに転送用の短いブロックを置く。
これによりflat命令の4整数幅を維持する。専用jump table命令は将来の測定後の改善とする。

### 4. handlerの有効範囲を明示する

初期実装はFrameごとのhandlerスタックを採用する。実行中にWasmのoperand stackやラベル探索を再現しない。
静的なHandlerDescriptorは、節の順序・tag・payloadの格納先・参照の格納先・分岐先PC・分岐先のhandler深さを保持する。
深さはFrame内の絶対深さであり、呼び出し元の深さとは混ぜない。

| MIR案 | 意味 |
|---|---|
| `EH_ENTER descriptor_id` | Frameにhandlerを登録 |
| `EH_TRIM depth` | 現Frameのhandlerスタックを指定深さまで縮める |
| `THROW throw_site_id` | tagとpayloadレジスタ列から例外値を作り、伝播処理へ移る |
| `THROW_REF source` | 参照がnullならtrap。それ以外は既存例外値を伝播 |
| `COPY_REF dst src` | 例外参照をコピー |

可変長のthrow payloadはFunctionのThrowSite表に置く。整数MIRには表のindexを保持する。
通常end、領域外へのbr/br_table、taken br_ifは必要なEH_TRIMを経由する。
try内loopへのbackedgeなど、handlerを維持する経路では解除しない。returnではFrameごと破棄する。
catch targetがloopの場合も同様に、飛び先で本当に有効なhandlerだけを残す。

例外伝播はRubyのraise/rescueでWasmフレームを巻き戻さず、VMの明示的なframes/poolsを操作する共通処理にする。

1. 現Frameの最内側handlerから、節を宣言順に照合する。
2. 一致しなければhandlerを除去して外側へ進む。
3. 一致したら捕捉handler自身と内側を解除し、さらに分岐先の深さまでtrimする。
4. payload/参照を対象Frameの指定レジスタへ書き、catch targetへ移る。通常callのreturn destinationには書かない。
5. handlerが尽きたFrameはpoolへ一度だけ返してcallerへ進む。callerのhandlerはcall待機中も維持される。
6. 全Frameで未捕捉なら、公開呼び出し境界で専用 `UncaughtWasmException` を送出する。tag/payloadを検査できる属性を持たせる。

trap、Rubyの実装バグ、整数ゼロ除算等をWasm例外へ変換しない。catch_allはRubyのStandardErrorを捕捉する処理ではない。
未捕捉例外・trap・通常終了のいずれでも、次の公開呼び出しにhandlerや例外値が残らないことを保証する。

### 5. 例外経路を解析・書き換えの対象にする

Opcodeの情報を、読み出し、通常書き込み、通常後続、Wasm例外を送出し得るか、trapし得るか、副作用に分ける。
CALLは戻り値の書き込みが正常復帰時だけに起き、例外経路では起きない。
全内部CALLを保守的にmay_throwとして扱い、関数単位の非送出推論は行わない。
整数除算はmay_trapだがmay_throwではない。THROW/THROW_REFには通常fallthroughがない。

Analysis/RegisterValidationに、保護されたCALL/THROW/THROW_REFから各catch targetへの例外edgeを追加する。
初期実装では照合可能性を細かく推論せず、静的に候補となる外側handlerも含めて保守的なedgeを張ってよい。
各例外edgeは「送出命令の直前の定義集合＋その節が渡すpayload/参照の定義」を持つ。
CALLの正常結果、送出命令より後の定義、他のcatch節だけが書くレジスタを混ぜない。
合流では全incoming edgeの共通部分を取る。handlerだけから到達するブロックも検証する。
基本ブロックを保護されたmay_throw命令で区切り、ブロック末尾の状態を送出地点の状態として流用しない。
handlerスタックの形も静的に照合し、通常edgeで矛盾する深さ・異なるhandler列が合流したMIRを拒否する。

通常分岐以外に、HandlerDescriptorのtargetもPC参照として列挙できるAPIを用意する。
Rewrite、Function#copy、profilingの命令挿入、Lowererが同じAPIを使い、すべてのPCを更新する。
意味MIRは命令ordinal、flatは4整数幅のoffset。元descriptorを破壊せずflat用descriptorへ変換する。
ThrowSiteのレジスタ参照もread解析とレジスタ置換の対象にする。Inspectionでhandler/throw表を表示する。

### 6. 最適化は安全な範囲から始める

M1b〜M1dではEH・参照を使う関数のcopy/immediate/branch/superinstructionを保守的に適用対象外とする。
Inliningもその関数への展開、その関数自身のcalleeとしての展開を両方止める。通常のi32関数の既存最適化は維持する。
これは既定設定でEHが動かないという意味ではない。既定設定でも関数ごとに安全な実行コードを作る。
EH専用の最適化解禁は別マイルストーンで行う。

EHを持たない関数でも、新しく加えるdiv/rem等を既存の純粋演算の数値opcode範囲へ無条件に入れない。
未使用結果でもtrapを消さず、最適化で例外・trapの順序を変えない。新opcodeは明示的なwhitelistで扱う。
flat lowering、profiling、framesはEHでも利用可能にする。検証自体をskipして通す実装は禁止する。

### 実装時の補足

- 通常関数の最適化passはCFGの集計情報だけを作り、完全な通常CFGは定義検証時に構築する。
  EH関数は例外edgeからleaderを得るため先に完全なCFGを作る。検証の省略はしない。
- handlerがないCALLには関数内の例外edgeがないため、その正常結果の隣接COPYとの合体を維持する。
  保護されたCALLでは例外edgeの定義集合を正常結果から分ける。
- CatchTargetのPC属性を`target_pc`とし、PCの書き換えは整数のmappingを使う。
  Spinelの汎用callbackからのnullable型推論が通常dispatchのPCへ伝播しないよう、
  MIR operandと保存PCの読み出し境界で整数であることを確定する。

## 内部マイルストーンとPRの順序

| 段階 | 推奨する変更単位 | 完了条件 |
|---|---|---|
| M1a-1 | 型付きレジスタメタデータ、Opcodeの意味情報、通常CFGの共通化 | 既存MIR・結果が維持され、全既存テストが通る |
| M1a-2 | i32比較、残りの演算・符号拡張 | M0のi32演算差分を正常系・境界・trapで確認 |
| M1a-3 | if/else/select | 合流、local旧値、短絡化しないselectを確認 |
| M1a-4 | br_tableの分岐列への展開 | 全target/default、重複target、結果転送を確認。M1の28命令が揃う |
| M1b-1 | tag/EHデコード、機能判定、block signatureと複数結果 | 外部validate済み入力と不正入力を区別。旧VMがEHを明示拒否 |
| M1b-2 | handler/throw表、EH_ENTER/TRIM/THROW、例外edge検証 | 同一関数のcatch/catch_allがsemantic/flat両方で動く |
| M1b-3 | call越しの伝播、pool解放、未捕捉API | 多段call・再帰・相互再帰・捕捉後の続行が成立 |
| M1c-1 | exnref型・参照レジスタ・local処理・COPY_REF | null初期化、スナップショット、複数値合流、参照クリアを確認 |
| M1c-2 | catch_ref/catch_all_ref/throw_ref | 保存後の再送出、外側での捕捉、null trapが成立 |
| M1d | profiler/検証/実行構成/性能/ドキュメントの統合確認 | 下記の受け入れ条件を満たす |

段階ごとにテストを追加する。M1dまでテストやflat実行の実装を先送りしない。
M1bでexnrefをデコードできても、実行機能が揃うまではfeature checkで拒否する。
途中のPRをmerge可能な状態に保ち、未対応機能を黙って読み飛ばさない。

## テスト計画

### M1a

- signed/unsigned比較: 0、1、-1、INT_MIN、INT_MAX。
- div/rem: 正負の組合せ、0除算、MIN/-1のdiv trapとrem=0。Rubyのfloor除算との差を確認。
- shift/rotate: 0、31、32、33、符号bit。clz/ctz(0)=32、popcnt(全bit)=32。
- extend8_s/extend16_s: 符号境界。結果は常に0..0xffffffffに正規化。
- ifの片側/両側非到達、elseなし、入れ子、結果付き分岐、分岐前に積んだlocalの旧値。
- selectの選ばれないoperand側にtrapがあっても評価されること。
- br_tableのdefault、大きなunsigned index、重複target、loop/外側blockへの分岐。

### M1b/M1c

- 同じ型の別tagを区別する。複数catchの順序、catch_allの位置、空のcatch列。
- payload=0個/1個/複数個。順序と値を確認し、multi-value転送のaliasをMIR単体でも検査。
- catch targetのdepth=0/外側/loop。try_table本体内brのdepthと混同しない。
- 正常end、return、br、br_ifのtaken/non-taken、br_table、loopのbackedgeごとにhandler寿命を確認。
- 直近handler不一致から外側へ伝播。calleeからcaller、複数Frameを越える伝播。
- callerのlocalは送出時点の値。CALLの未完了結果をcatch経路で読み出せないことを負のMIRテストで確認。
- throw後は非到達でもcatch targetは到達可能。catchだけで定義される値の漏出を拒否。
- 捕捉して参照localへ保存、別callを挟んでthrow_ref、元のtag/payloadを維持。
- 再送出を元の捕捉handlerが再捕捉せず、外側handlerが捕捉する。
- nullのthrow_ref、unreachable、0除算をcatch_allが捕捉しない。
- 再帰・相互再帰の各Frameが独立。巻き戻したFrameを再利用しても古いhandler/参照が残らない。
- 未捕捉例外とtrapの後、同一VMへ再度callできる。startからの未捕捉例外も専用エラーになる。
- 旧VM、imported/exported tag、非i32 payload、block引数等の拒否。未export/非到達部分も対象。

### 最小受け入れ例

次の2つのexportは、実装後にそれぞれi32の42を返すことを期待する。
2026-11-05に `wasm-tools 1.218.0` のparse/validateは成功した。Warditeでの実行と外部エンジンとの比較は未実施。
この例は複数結果block、深さ0のcatch target、関数越しの伝播、exnrefローカル、再送出をまとめて通す。

```wat
(module
  (tag $e (param i32))
  (func $raise
    i32.const 42
    throw $e)
  (func (export "catch_call") (result i32)
    block $done (result i32)
      try_table (catch $e $done)
        call $raise
      end
      i32.const 0
    end)
  (func (export "rethrow") (result i32)
    (local $saved exnref)
    block $outer (result i32)
      try_table (catch $e $outer)
        block $inner (result i32 exnref)
          try_table (catch_ref $e $inner)
            call $raise
          end
          unreachable
        end
        local.set $saved
        drop
        local.get $saved
        throw_ref
      end
      i32.const 0
    end))
```

### 実行構成と参照実装

通常命令は旧VM・未最適化MIR・既定MIRで比較し、M0に記録した旧VMの問題は独立期待値を正とする。
EHは旧VMへfallbackしない。固定した期待値に加え、新形式EH対応を確認した外部エンジンを参照にする。
実装時に候補のバージョン・有効化オプションと小さなEH実行を記録してから採用する。特定エンジンが対応済みと仮定しない。
`wasm-tools parse` と `validate` は入力の確認であり、実行結果の参照実装の代わりではない。
参照エンジンが用意できなければEHの外部比較を未完了と記録し、M1d全完了を宣言しない。

CRuby/Spinelそれぞれで、default、all無効、flatのみ無効、framesのみ無効、profiling有効を検証する。
M1aは既存各passの個別無効化も確認する。EHはpassの保守的除外が既定設定でも守られることを検査する。
意味MIR/最適化MIR/flat descriptorの所有関係とPC更新も確認し、profiling後に元IRが変わらないことをテストする。

```sh
bundle exec rake test
bundle exec rake check
make spinel-test RUBY="bundle exec ruby"
```

checkは生成RBSを更新するため差分を確認する。Spinelテストが省略された状態をSpinel検証成功とは扱わない。
既存 `benchmark/i32_mix.wat` とcall arityケースで、実装前後のchecksum・実行時間・ロード時間を比較する。
既存benchmark/compare.rbの作業中の変更を上書きしない。計測のコマンド、環境、反復回数、分布を記録し、単発値で判断しない。
EHなしのi32ループにref型判定やhandler探索を持ち込まない。再現する退行は原因を説明・修正してから閉じる。
EH固有の高速化率はM1の完了条件にしない。

## 変更箇所の見取り図

| ファイル | 主な責務 |
|---|---|
| `lib/wardite/const.rb`, `instruction.rb`, `load.rb` | tag、EH operand、型、blocktype、構造化制御のデコード |
| `lib/wardite.rb` | 早期feature check、tag格納、default_localsの分離、旧VMの拒否 |
| `lib/wardite/errors.rb` | 未捕捉Wasm例外とtrapの区別 |
| `efflorescence/translator.rb` | 型付き抽象スタック、if、複数値転送、handler領域の出入り |
| `efflorescence/ir.rb` | レジスタ型、参照bank、HandlerDescriptor/ThrowSite、Frameの後始末 |
| `efflorescence/optimizer.rb` | Opcode情報、通常/例外edge、全PC参照の更新、安全なpass適用、flat化 |
| `efflorescence/register_validation.rb` | 例外edge固有の定義と型、handler状態の検証 |
| `efflorescence/vm.rb` | 両dispatch、共通の明示的巻き戻し、未捕捉API |
| `efflorescence/inspection.rb` | handler/throw表の表示、profiling後のPC整合性 |
| `test/`, `sig/generated/`, `docs/` | 回帰・拒否テスト、RBS、対応範囲と制限の更新 |

Efflorescence配下のパスは `lib/wardite/` からの相対パス。
既存ALUの生成テンプレートは意味の確認に使えるが、旧VMのstack操作をEfflorescenceから呼び出す実装はしない。

## 採用しない案と再検討条件

- Rubyの例外機構でWasm EHを直接実装: 明示的なWasm Frameとpoolの寿命が一致せず、trapとの混同も起きやすいため採らない。
- 全レジスタをObjectの配列へ変更: 既存i32/Spinelの実装前提を崩すため採らない。
- PC範囲だけでhandlerを検索: 将来候補だが、初回は命令の移動と領域境界の管理より、明示的ENTER/TRIMを優先する。
- EH関数にも既存最適化をそのまま適用: 例外edgeでの値の生存をまだ証明できないため採らない。
- 旧VMへのEH実装を前提にする: 本件のスコープ外。比較のためだけには実装しない。

Spinelが参照bankの型を扱えない、handler状態の解析が収束しない、EHなしの経路に大きな退行が出る場合は、失敗した最小例と計測を残して設計を再検討する。
Sol/Lunaで難しい設計問題に突き当たった場合は、ユーザーのAGENTS.mdに従いAstraへの切り替えを提案する。
検証を外す、旧VMへfallbackする、すべてをRuby rescueで捕捉する方法で回避しない。

## 参照

仕様の根拠と本ADRの実装方針は区別する。MIRの命令名、参照bank、handlerスタック、passの除外はWardite向けの設計判断である。

- [公式EH explainer](https://github.com/WebAssembly/spec/blob/main/proposals/exception-handling/Exceptions.md): 新形式の命令・節、tag/例外参照、バイナリ形式。2026-11-05確認。
- [Coreの検証規則](https://webassembly.github.io/spec/core/valid/instructions.html): 制御と値型の検査。実装時は使用した仕様revisionを記録する。
- [Coreの実行規則](https://webassembly.github.io/spec/core/exec/instructions.html): 分岐と例外伝播の意味。
- [レジスタ初期化の設計](../efflorescence-register-initialization.md): 現在のdefinite assignmentとpoolの前提。
