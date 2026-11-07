# ADR 0004: Efflorescence M4のi64対応

- 状態: 提案。実装・性能検証は未実施。
- 日付: 2026-11-08
- 調査基準: main `17200af`（M3とWASI専用経路のmerge後）
- 前提: [M0調査](../efflorescence-coverage-ja.md)、[M3実装](../efflorescence-m3.md)、[ADR 0003](0003-efflorescence-m3-host-and-indirect-calls.md)

## 到達点と範囲

M4でM0のi64・整数間変換47命令を追加し、i32/i64が混在する関数、Store、EHを成立させる。
実行は引き続きflatのみ。意味MIRは変換・検証・表示に保持する。

| 分類 | 内容 |
|---|---|
| i64 ALU等（30） | const、eqz、10比較、clz/ctz/popcnt、add/sub/mul、div_s/u、rem_s/u、and/or/xor、shl/shr_s/u、rotl/rotr |
| i64 memory（11） | load、load8/16/32のs/u、store、store8/16/32 |
| 整数間変換等（6） | i32.wrap_i64、i64.extend_i32_s/u、i64.extend8/16/32_s |
| 値の流れ | 引数・単一結果・local・const・select・block結果・global・tag payload |
| 呼び出し | 直接/間接、defined/imported、再export、再帰、ホストからの再入 |

floatとの変換・reinterpret・trunc_satはM5。multi-value関数、block/loop引数、memory64、table拡張、tag import/export、ホスト例外のEH化は追加しない。
メモリアドレス・memory.growのdelta・table selectorはi32のまま。i64のshift量はi64オペランドの下位6bitを使う。
関数結果はvoidまたは単一i32/i64。startは従来どおり引数・結果なし。

## 1. 値表現を固定する

### 内部は符号付き64bit整数

Frame.registersのArray[Integer]を維持する。i32は0..0xffffffff、i64は-2^63..2^63-1の正規化値とする。
例外参照bankはM1のまま。型はFunction.register_typesで決め、hot loop内でObjectの型判定をしない。
「すべての整数レジスタがunsigned i32」という既存コメント・検証・戻り値処理を更新する。

unsigned i64をそのままArray[Integer]へ入れる案は採らない。既存I64.valueはSpinelの型推論に依存してunsignedを保持できるが、固定した整数配列でも同じになると仮定しない。
i64用のboxed配列も導入しない。内部演算・内部callごとのI64 allocationを避ける。

### 分解と合成

low = value & 0xffffffff、high = (value >> 32) & 0xffffffff とし、両limbをunsigned 32bitで保持する。
合成は `low | ((high & 0x7fffffff) << 32) | ((high >> 31) * INT64_MIN)` とする。
この式ではINT64_MINを `-9223372036854775807 - 1` として表し、正の2^63や2^64を中間値として作らない。
最終maskで帳尻を合わせる前にオーバーフローする式を使わない。

専用I64Arithmetic helperを新設し、演算を集約する。Frameを渡してdestinationへ書く方式などで、毎演算のlimb配列allocationを避ける。
helper単体の正しさを先に検証し、VMは旧stack Evaluatorを呼ばない。
値表現を変更する必要が判明した場合はM4aでADRを更新し、後のフェーズへ未解決のまま進まない。

## 2. 算術の実装方針

| 演算 | 方針 |
|---|---|
| add/sub | lowのcarry/borrowをhighへ渡し、各limbを32bitで切る |
| mul | 16bitの4桁へ分解。下位4桁へ寄与する積とcarryだけを計算 |
| signed比較 | 正規化済みsigned値を比較 |
| unsigned比較 | highを比較し、同じならlowを比較 |
| eq/eqz・大小比較 | 出力はi32。i64レジスタへ書かない |
| and/or/xor | signed表現のbit演算。最終結果もsigned64の範囲にあることを検証 |
| shift/rotate | k=rhs & 63。0、1..31、32、33..63を分けてlimb演算 |
| clz/ctz/popcnt | limbごとに計算し、結果はi64。ゼロのclz/ctzは64 |
| extend/wrap | 下位bitと符号bitから明示的に変換。wrapはlowをi32として返す |

unsigned div/remは初回実装で64ステップのlong divisionを使う。quotient/remainderをlimbで保持し、remainderを左へ送る際の65bit目のcarryを別に保存して比較・減算する。
65bit目を捨ててから比較しない。RubyのBignumやSpinelのoverflow promoteを前提にしない。
signed div/remはlimb上で符号を外し、unsigned kernel後に符号を戻す。INT64_MINのabsをRuby整数で作らない。
div_sのMIN/-1はtrap、rem_sのMIN/-1は0。除算は0方向への切り捨て、余りの符号は被除数に従う。
0除算はM1と同じtrapで、Wasm EHでは捕捉しない。性能改善のための除算fast pathは初回の完了条件にしない。

## 3. Translator・MIR・検証

i64.constを読み込み、MIRへ保存する前にsigned64へ正規化する。共有デコーダーが上位bit付き定数をSpinelで失わないこともテストする。
constの重複排除キーを型と値の組にする。i32の1とi64の1を同一レジスタへ割り当てない。
定数・local初期値のi64は0。Frame再利用時にも型に依らず数値localを0へ戻す。

新opcodeは明示的なread/destination/type規則を持つ。数値opcodeの連続範囲判定だけに追加しない。
COPYはi32→i32またはi64→i64で利用し、異型間COPYを拒否する。変換は専用opcode。
比較のi32出力、count演算のi64出力、shiftのi64右辺、selectのi32条件をそれぞれ検証する。
複数結果blockのparallel copy、local旧値snapshot、br/br_if/br_tableも型を維持する。
未export関数・非到達命令でも即値・型・対応範囲を検査する。

初期M4ではuses_i64を導入し、その関数のlocal passと双方向inliningを保守的に除外する。
uses_eh/uses_store/uses_dynamic_callsの除外も維持し、i32のみの既存fast pathは変更を最小限にする。
validation、profiling、framesはi64でも常に動く。未使用div/remのtrapを削除しない。
IR.copy、Lowerer、Inspection、side table、profilingの型情報を揃える。

## 4. 呼び出しと公開API

FunctionEntryの型列でargument/resultを判別し、内部callではsigned64のままコピーする。
直接CALLの単一引数fast pathは数値コピーなので維持できる。RETURNのi32固定の正規化・RBSを見直す。
間接callの比較は型列の完全一致とし、同じbit幅の値を渡せてもi32/i64の型不一致はtrapにする。

公開callの結果は型に応じI32またはI64、voidはnil。
call_unboxedのi32結果は従来のunsigned Integerを維持し、**i64結果はsigned64 Integer**を返す。
この新規契約を文書化し、0xffffffffffffffffのi64は-1、符号なしの値が必要ならcallのI64.valueを利用する。
内部表現をAPIの都合でunsignedへ戻してSpinelの整数幅を越えない。

i64の公開引数はIntegerまたはWardite::I64を受ける。i32引数の既存契約は変更しない。
Integerの下位64bitをsigned64へ正規化し、I64はvalueのbit列から変換する。
CRubyの大整数入力も下位64bitを使う。Spinelでは表現可能なIntegerとI64からの入力を検証し、表現できないRuby入力そのものの生成を保証しない。

通常host ABIの引数配列はArray[wasmValue]として型ごとにI32/I64へboxingする。
i64結果にIntegerまたはI64を受け、signed64へ正規化する。I32/F32/F64等の誤ったwrapperは拒否する。
voidはnilのみ。host実行は一度だけとし、変換失敗時に再試行しない。
M3の再入コンテキストとmetricsの所有権、ホストRuby例外とWasm EHの境界は維持する。

## 5. memory・global・EH

M2のchecked memory helperを再利用し、i64 load/storeの幅8byteと狭幅を追加する。
バイト列はlittle endian。native pack/unpack幅・エンディアンに依存しない。
loadはlow/highを組み立て、signed/unsigned狭幅loadの拡張を明示する。storeは必要な下位byteを出す。
全範囲を先に検査し、失敗時に部分更新しない。effective addressを32bitへwrapしない。

global.get/setは型ごとにI64とsigned64を相互変換する。Storeが唯一の保持元であり、別のglobal cacheを持たない。
shared I64.valueの符号・上位bit表現を変更せず、境界helperを利用する。

tag payloadにi32/i64の混在を許す。ExceptionValueのpayloadはtag型列と対応する正規化整数列とし、i64はsigned64。
既存i32のpayload契約を維持する。公開UncaughtWasmException.payloadのi64はsignedであることを文書化する。
throwでコピーしてからFrameを解放し、catch先へ型を保って転送する。throw_refは元の例外値を保持する。
catchのpayload定義、複数結果block、例外edge上の型検証を拡張する。tagの同一性はシグネチャとは別に維持する。
メモリtrap・整数trapをWasm例外へ変換しない。

## 6. M3のWASI改善を維持する

fd_write/proc_exitの整数ABI専用経路はi32専用のまま残す。
リンク時の実体・シグネチャ照合を維持し、同名の通常host関数を誤って専用経路へ送らない。
i64を含むWASI関数は通常boxed ABIを使い、個別の高速化はM4に含めない。

CRubyでは既存のi64引数を持つWASI関数を1つ選び、実装内容を確認して一時ファイル等の制御可能な入力で縦通しを検証する。
対象関数、引数・戻り値、errno・memoryへの効果を実装記録へ残す。既存WASI全体の正しさや対応完了は宣言しない。
SpinelのWASI拒否は維持し、通常WasmModule/HashModuleでi64 host ABIを検証する。

## 内部フェーズとコミット

**内部フェーズごとにコミットを作る。** 実装・テスト・必要な生成RBSを揃えて検証し、コミットしてから次へ進む。
全段階を最後に一つへまとめない。各段階は複数コミットへ分割してよい。
途中段階では未完成の命令・型経路を明示拒否し、既存i32機能を壊さない。
メッセージは簡潔にし、`Co-authored-by: Codex <codex@openai.com>`を付ける。

| フェーズ | 実装 | 完了条件 |
|---|---|---|
| M4a | signed64境界helper、limb分解/合成、型付き定数とregister、uses_i64 | CRuby/Spinelで上位bit・MIN/MAX・型の区別が成立 |
| M4b | const/local/COPY/select/制御転送、内部call/return、公開API | i32/i64混在の直接call・再帰・単一結果とFrame再利用が成立 |
| M4c | 比較・bit/count・shift/rotate・6変換 | 型規則と境界値、0/32/64周辺のshiftが成立 |
| M4d | add/sub/mul/div/rem | limb carry、MIN/-1、全符号・0除算、独立期待値と一致 |
| M4e | memory/global・EH payload | 全幅、混在payload、catch/再送出、trapと状態保持が成立 |
| M4f | host/間接call/再export/再入、WASI接続 | 混在ABI、型trap、専用i32経路の回帰が成立 |
| M4g | 外部比較・profiling・性能・文書 | 全47命令と関連経路の受け入れ条件を満たす |

M4aは表現の設計ゲート。実際のSpinelコンパイルと実行を省略しない。
M4bの段階でhost/間接のi64型を受理し始めない。M4fまで経路別feature checkで拒否する。
同様にi64 tag/globalもM4eまで拒否し、未実装経路への型の流入を防ぐ。

## 受け入れ条件

- 値集合: 0、1、-1、2^31/2^32/2^63の前後、INT64_MIN/MAX、全bit、交互bit。
- limb分解→合成の往復、typed constantの非共有、I64.valueとの相互変換、公開signed結果の契約。
- add/sub carry/borrow、mulの桁間carry、MINの符号反転、unsignedで上位bitの立ったdiv/rem。
- shift/rotate量0/1/31/32/33/63/64/65/-1、clz/ctz(0)、全bitのpopcnt。
- signed比較とunsigned比較が異なるケース。比較結果をi32条件として分岐できること。
- divの0方向丸め、remの符号、MIN/-1のdiv trapとrem=0、0除算がcatch_allを通らないこと。
- mixed local、local.teeと旧値snapshot、if/br_table/複数結果block、再帰・相互再帰、frames無効化。
- typed host引数順序、0/1/多引数、Integer/I64結果、誤wrapper拒否、再export、型indexが異なる同型の間接call。
- hostから再入してi64を返す、失敗後に外側を継続する、call直前の値と正常return destinationの区別。
- memory幅8/4/2/1、符号境界、未整列、最終有効byte、範囲外offset、失敗時の不変性、global更新後のsnapshot。
- tagのi32/i64順序、catch_refで保存して再送出、未捕捉payload、Frame解放後の値維持。
- profiling・all無効・frames無効・既定設定で結果が一致し、元IR/side tableを変更しない。

CRubyの任意精度整数で独立した参照計算を作り、固定seedのランダム入力も比較する。
参照ではmod 2^64を利用してよいが、その実装を本体helperへコピーしない。
同じ固定入力・期待値をSpinelでも使い、native overflowチェックを無効にしない。
旧VMとの一致だけでは合格にせず、i64単体と混在制御/間接/EHを参照エンジンでも確認する。
実装時にWasmtime等のversionとEHオプションを確認し記録する。非i32引数を扱えない旧公開APIはWasmラッパーで比較する。

```sh
bundle exec rake test
bundle exec rake check
make spinel-test RUBY="bundle exec ruby"
```

checkによる生成RBSを確認し、Spinel省略を成功として扱わない。
M3のi32_mix/call arity/4種類のcall、WASI fd_write/proc_exitを回帰対象にする。
i64 benchは整数演算、除算、memory、混在callを分ける。checksum、ロード時間、実行時間、boxing数を記録する。
内部call/演算のallocationを調べ、I64が毎回生成されていないことを確認する。
比較基準はM3のmain。M3で残っていた差とM4で新たに導入した退行を区別する。
再現するi32 fast pathの退行は原因を説明・対処してから閉じる。i64の高速化率は完了条件にしない。

## 変更箇所と設計を戻す条件

| 箇所 | 作業 |
|---|---|
| lib/wardite/efflorescence/i64_arithmetic.rb（新規案） | 分解/合成とallocationを抑えた安全な演算 |
| translator.rb、ir.rb | 型・定数・新opcode・uses_i64・call/tag/Storeの型経路 |
| vm.rb | flat演算、公開API、RETURN、host ABI、混在call |
| store_access.rb | checked i64 memory/global、byte順序 |
| register_validation.rb、optimizer.rb、inspection.rb | 型と例外edge、除外規則、lowering、copy、表示・計測 |
| wasi.rb | 既存専用経路の維持とboxed ABIの縦通し確認 |
| lib/wardite/value.rb、load.rb | 必要な境界/デコードの局所修正。共有変更は旧VM回帰付き |
| test、sig/generated、docs | 単体・統合・拒否・外部比較、生成型、M4実装記録 |

省略したパスはlib/wardite/efflorescenceからの相対。
既存I64の演算は参考にするが、unsigned value表現やnative packを内部VMへそのまま持ち込まない。
Spinelでsigned配列が維持できない、境界変換で上位bitが失われる、i32経路に大きな退行が出る場合は最小再現と計測を残して設計を戻す。
Sol/Lunaで解決困難な設計問題に突き当たった場合はAGENTS.mdに従ってAstraへの切り替えを提案する。
Bignum依存・overflow promote・旧VMへのfallback・検証skipで回避しない。
