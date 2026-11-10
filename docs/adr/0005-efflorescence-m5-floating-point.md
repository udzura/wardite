# ADR 0005: Efflorescence M5のf32/f64と数値変換

- 状態: 提案。実装・検証は未実施。
- 日付: 2026-11-10
- 基準: main `b50073d`（M4実装後）
- 前提: [M4実装](../efflorescence-m4.md)、[M0一覧](../efflorescence-coverage-ja.md)
- 完了後の照合: [ADR 0006](0006-efflorescence-m6-coverage-parity.md)

## 決定と範囲

M0のM5に分類された76命令を実装する。f32/f64各23命令（const、memory、比較、演算）と、浮動小数点を含む30変換命令が対象。
f32/f64のlocal、select、block結果、global、関数引数・単一結果、host、直接/間接call、EH payloadも対象にする。
実行はflatのみ。関数multi-value、block引数、SIMD、typed select、GC、tag import/export、host例外のEH化は追加しない。
WASI専用i32 ABIと通常boxed ABIの分離を維持する。

## 値表現

整数レジスタbankを維持し、floatはIEEEの**生のbit列**を格納する。
f32はunsigned32、f64はM4のsigned64で64bit列を表す。register_typesで数値の意味を区別する。
浮動小数点演算の入口/出口だけでRuby Floatとbit列を変換するFloatArithmetic helperを作る。
専用Float bankを正本にしない。NaN payload、符号付きゼロ、reinterpret、コピーをFloatへの変換で失わないためである。
内部call/COPYではbit列をそのまま転送し、毎回F32/F64を生成しない。

定数は型とbit列で重複排除する。+0と-0、異なるNaN payloadを統合しない。
共有ローダーは現在float即値をFloatへunpackするため、Efflorescence用のraw bitsを保持できるoperand表現へ拡張する。
旧VMには従来のFloat取得を提供し、共有型変更の回帰テストを追加する。
local初期値は+0のbit列。Frame再利用、snapshot、parallel copyもbit列を保つ。

bits↔Floatの変換は明示的な32/64bit・little endian指定を使う。native幅のpack形式に依存しない。
f64のsigned64と上位bitの変換はM4 helperを利用し、正の2^63をSpinelの整数配列へ入れない。
CRuby/Spinel両方でpack/unpack等の利用可能性とbitの往復をM5aで実証する。

## 演算の意味と丸め

abs/neg/copysignはbit操作で実装する。load/store、const、reinterpret、local/COPYもbitをそのまま保持する。
算術で生じたNaNは仕様が許すcanonical NaNへ統一してよい。入力bitを維持する操作と、算術NaNの許容集合を混同しない。
比較の結果はi32。NaNとのeq/大小比較はfalse、neはtrue、+0と-0は等しい。
min/maxはNaNを明示処理し、ゼロ同士はminで-0、maxで+0を選ぶ。

nearestはties-to-even。Rubyの既定roundをそのまま使わない。
ceil/floor/trunc/nearestは±0、infinity、NaNを先に処理し、FloatDomainErrorや巨大Integerへの変換を避ける。
sqrtの負数はNaN、sqrt(-0)は-0。0除算等のfloat演算は整数divと異なりWasm trapにしない。
各命令の出力をその型へ丸める。f32の複数命令をf64精度のまま連続実行しない。

f64はhost binary64の既定丸めを使えることを検証する。
f32は「Ruby Floatで演算して最後にpackすれば常に正しい」と仮定しない。div/sqrt等の二重丸めとsubnormalを含め、binary32の直接丸めとの差を確認する。
M5aで実装可能性を判定し、差が出る演算には整数のsignificand/exponentからguard/round/sticky bitで丸める補正またはsoftware kernelを設ける。
Ruby/Spinelのfast-math、FTZ、FMAによる意味変更に依存しない。近似誤差の許容幅で不一致を隠さない。
M5aのゲートを通るまで算術全体の受理を有効にしない。難しい丸め問題は最小例を残してAstraへの切り替えを提案する。

## 数値変換

整数→floatは元のsigned/unsignedを明示し、i64 unsignedはM4のlimbから解釈する。
i64→f32はi64→f64→f32の二重丸めを避け、整数の有効bitから目的精度へ直接丸める。
高位bit、丸め境界、tieのeven/odd、carryによる指数増加を独立検証する。
f32→f64は有限値を正確に拡張し、f64→f32は目的精度へ丸める。NaNは許容される形で処理する。

float→integerのtruncはbit列から符号・指数・仮数を解釈し、切り捨てた数学的整数が範囲内かを判断する。
NaN、infinity、範囲外はtrap。unsignedへの(-1,0)は0となり得るため「入力が負ならすべてtrap」としない。
最大整数をFloatへ変換して比較すると閾値が丸まるため、範囲判定をその方式に依存させない。
trunc_satはNaNで0、その他は目的型の範囲へ飽和する。trapしない。
i64結果はsigned64へ合成し、unsignedの上位半分も失わない。
reinterpretは同幅のbit転送であり数値変換しない。f32↔i32、f64↔i64を両方向で検証する。

## 呼び出し・Store・EH・API

call_unboxedのfloat結果はRuby Float、callはF32/F64を返す。i32 unsigned、i64 signed、void nilの既存契約を維持する。
float引数はRuby Floatまたは対応するF32/F64 wrapperを受け、f32は境界でbinary32へ丸める。誤wrapper、Integerの暗黙float変換は拒否する。
通常host ABIは型順にI32/I64/F32/F64を渡し、float結果はFloatか対応wrapperのみ受理する。
Ruby Floatを通る公開境界でNaN payloadの完全保持は保証しない。内部のbit保存をこの制約で弱めない。

現在のVMの戻り値Integer契約を、内部のbit carrierと公開のFloat変換に分ける。
内部RETURNは常に整数bit carrier。結果型による公開変換をdispatch外の専用helperで行い、hot loopへInteger|Float unionを持ち込まない。
間接callの型はf32/f64も厳密に比較し、再入コンテキスト・metricsの所有権を維持する。

load/storeはM2の範囲検査後にraw bytesを転送する。途中でFloatへ変換しない。
globalは共有Storeを正本とする。F32/F64にraw-bit取得/生成経路を追加し、globalへの出し入れでNaN payloadを失わないようにする。
既存のvalue=更新とraw bitsが不整合にならない設計にする。別cacheを黙って保持しない。

ExceptionValue.payloadは内部では型付きbit carrier列を保持する。
公開UncaughtWasmException.payloadはtag型に応じfloatをRuby Floatへ変換し、i32/i64の既存契約は維持する。
内部payloadの名前と公開アクセサを分離し、catch/throw_refは公開変換を経由しない。
float trunc trapをcatch_allへ流さず、通常のthrowのfloat payloadだけを例外edgeで転送する。

## IR・最適化

新opcodeにinput/output型を明示する。f32/f64比較はi32出力、trunc_satは非trap、truncはmay_trap・非may_throw。
COPYとselect、block合流、host side table、tag、IR.copy、Inspection、定義検証を型付きで拡張する。
uses_floatを設け、初回は当該関数のlocal passと双方向inliningを除外する。他の除外規則とi32 fast pathを維持する。
profiling、flat lowering、frames、validationは有効にする。typed constantとraw bitsをdumpできるようにする。

## 内部フェーズとコミット

**内部フェーズごとにコミットを作る。** 実装・テスト・必要な生成RBSを検証してコミットし、次へ進む。
全段階を一つにまとめない。大きいフェーズは分割可。未完成の型経路は明示拒否する。
メッセージは簡潔にし、`Co-authored-by: Codex <codex@openai.com>`を付ける。

| 段階 | 作業 | 完了条件 |
|---|---|---|
| M5a | bit表現、decode、FloatArithmetic試作、丸め方式選定 | 両runtimeでbit往復・特殊値・丸め境界を実証。採用kernelを記録 |
| M5b | const/local/COPY/select/制御、内部call/API | 型付き定数、±0、NaN bit、混在callとFrame再利用 |
| M5c | 比較・abs/neg/copysign・丸め・四則・sqrt/min/max | 特殊値と目的精度の期待値に一致 |
| M5d | 30変換命令 | 整数境界、直接丸め、trunc trap、sat、reinterpret |
| M5e | memory/global/EH | 全幅、raw bit保持、混在payload、再送出 |
| M5f | host/間接/reexport/再入 | 4数値型混在ABI、型trap、既存WASI専用経路の回帰 |
| M5g | 外部比較・profiling・性能・記録 | 76命令と値の通る経路の対応表を完成 |

## 検証と完了条件

固定bit fixtureを使い、±0、最小subnormal、最小normal、最大finite、±infinity、複数NaN payload/sign、丸めtieの上下を確認する。
nearestの±0.5/1.5/2.5、sqrt(-0)、0/0、非ゼロ/±0、infinity同士、min/maxのゼロを含める。
truncは各型のMIN/MAX近傍の表現可能float、(-1,0)、NaN/infinity。satは同じ入力で比較する。
i64→f32の二重丸めケースを必須fixtureにする。
bit保存命令は完全一致、算術NaNは仕様上の許容集合で判定し、Float#==だけで比較しない。
参照エンジンと固定seedのbit入力を比較し、同一helperを期待値生成へ使わない。

CRuby/Spinelで既定・all無効・frames無効・profiling有効を実行する。
`bundle exec rake test`、`bundle exec rake check`、`make spinel-test RUBY="bundle exec ruby"`を通す。省略を成功扱いしない。
旧VMのnearest等の既知不一致を複製しない。M4のi32/i64/call/WASI benchを回帰対象にし、floatの演算・変換・mixed callを別計測する。
性能改善率は要件にしないが、整数fast pathの新しい退行は原因を説明・対処する。
実装記録へkernel選定、仕様/参照エンジンrevision、結果、制限を記載してM6へ渡す。

## 変更箇所・根拠

FloatArithmetic（新規）、translator/ir/vm、store_access、register_validation、optimizer、inspection、共有load/value、test、sig/generatedが対象。
共有変更は旧VM回帰も含める。Spinelで必要なbit操作・丸め方式を実証できなければM5aで設計を戻す。
[公式Numerics](https://webassembly.github.io/spec/core/exec/numerics.html)を演算と変換の根拠にし、bit carrier・kernel分離・段階構成はWardite側の設計判断とする。
