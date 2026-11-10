# ADR 0006: Efflorescence M6の既存対応範囲との一致

- 状態: 実装・検証済み。[実装記録](../efflorescence-m6.md)
- 日付: 2026-11-10
- 基準: main `b50073d`、[M0調査](../efflorescence-coverage-ja.md)
- 前提: [M5 ADR](0005-efflorescence-m5-floating-point.md)とM1〜M4の実装記録

## 決定

M6は「旧VMの実装対象に対する対応漏れ」と「複合実行・公開境界の漏れ」を解消する段階とする。
Wasm全仕様、旧VMの不具合との完全互換、default engine切替、性能最適化の全面解禁は目標にしない。
基準はM0でデコードから実行経路があると数えた188命令。新形式EH3命令と関連拡張は別枠の回帰対象。
M4後の単純集計は65+47=112、M5の計画は+76=188だが、算術上の一致だけで完了としない。
M0文書の現在状況はM3の65命令で止まっているため、実装後の表と履歴を分けて更新する。

## 対応表を実行証拠と結び付ける

機械可読manifestをtest/support等へ置き、opcodeごとに以下を管理する。

- Wasm opcodeと内部名、共有decoder・Translator・VM経路、導入フェーズ。
- 正常系・境界値・trap（該当なしの理由も可）のテストID。
- CRuby/Spinelの実行結果、参照エンジン比較の有無。
- 型・signature・memory/table/import等の制限、既知不一致と理由。

命令名のgrepやTranslatorのwhenの数を実行カバレッジとみなさない。
fixture実行時に対象opcodeが実行されたことをprofiling等で確認し、最適化で消える場合は最適化無効の実行で裏付ける。
ゼロ実行・skip・期待値なしのfixtureを対応済みに数えない。全命令を毎回profilingする必要はなく証拠生成用の専用runを設けてよい。
M0対象にmanifestの欠落/重複があればテストを失敗させる。

開始時点で旧VMとdecoderを再照合する。M0以降の追加は差分として列挙し、自動で今回の対象へ混ぜない。
旧VMに元からないtable命令、data.drop、legacy EH等は除外を維持する。
到達不能な生成ハンドラを対象へ戻さない。

## 比較ハーネス

各ケースはengineごとに独立instanceを作る。連続callを確認するケースだけ同一instanceを明示的に共有する。
戻り値だけでなくmemory bytes/current、global、host呼び出しの引数・順序・回数、stdout、trap、未捕捉例外を比較する。
Rubyクラス名やエラーメッセージの完全一致は要求せず、仕様上のtrap種別と副作用の位置を比較する。
floatはbit保存と算術NaNの許容集合を分ける。浮動小数点の一般的な許容誤差で差を隠さない。
旧公開APIが非i32引数を受けない場合はWasm wrapperで内部へ渡す。Efflorescenceの拡張APIは独立テストで検証する。

旧VMの既知の誤動作は参照エンジン・独立期待値を優先する。旧VM側の不一致を記録し、同じ誤動作をEfflorescenceへ移さない。
参照エンジンのversion/optionsとfixtureを固定する。通常hostのRuby契約はspy callableで検証する。
既存spec/runner.rbは非i32値、NaN、複数結果、skipの扱いを確認してから利用する。既存runnerを全仕様の正解判定器と仮定しない。

## 必須の複合ケース

| 分類 | 確認する経路 |
|---|---|
| 初期化 | active/passive data、global初期値、element、startと失敗順序 |
| API | 4数値型、void、defined/imported export、引数個数と型拒否 |
| call | 直接/間接、前方参照、再帰、mixed型、hostから再入、異常後の再call |
| Store | global snapshot、grow後のdata参照、bulk重複、instance分離 |
| EH（追加範囲） | mixed payload、call越し捕捉、再送出、trap非捕捉、Frame解放 |
| 最適化 | 既定/all無効/各pass無効、除外関数の規則、frames無効、profiling |
| 拒否 | 未export/非到達の未対応命令、不正index/型、未対応signature/features |
| WASI | M3 fd_write/proc_exitとM4 path_openの回帰。全WASI対応とは呼ばない |
| CLI/inspect | engine選択、invoke/start、dump、profile、既存CLI結果形式 |

CRuby/Spinelの双方を必須にする。SpinelでWASIを拒否する既存制約は正常な拒否テストとして扱う。
EH/host/floatを追加した分、旧VMでは扱えないケースを比較runから分け、黙ってskipしない。

## 残項目の修正方針

漏れを「未実装」「誤結果」「trap/副作用」「共有decoder」「API」「試験不足」「対象外」に分類する。
対象内の漏れは再現fixtureを先に作り、最小修正・旧VM回帰・Spinel検証を同じフェーズで行う。
共有loaderに完全validatorを新設することは必須にしないが、対象命令の不正即値・型・index検査は確認する。
全仕様の不正モジュール試験が未完でも、対象内の失敗を仕様外というラベルで隠さない。

対象外の新機能や重大な設計変更が必要なら別ADRへ切り出し、対象内の受け入れ条件が残る場合はM6未完了とする。
旧VMの全不具合修正、tag import/export、host例外のEH化、multi-value関数、block引数、multi-memory等を自動で追加しない。
default engineの切替とuses_i64/uses_float等の最適化除外解除は、対応範囲が揃った後の別判断。

## 内部フェーズとコミット

**内部フェーズごとにコミットを作る。** 検証結果と必要な文書/生成RBSを含め、次へ進む前にコミットする。
フェーズ内の修正は問題群ごとに分けてよい。最後に全体を一つのコミットへまとめない。
メッセージは簡潔にし、`Co-authored-by: Codex <codex@openai.com>`を付ける。

| 段階 | 作業 | 完了条件 |
|---|---|---|
| M6a | 対象再照合、manifest、M0の履歴/現在表の分離 | 188命令と追加EHの対応が追跡可能。差分と制限を列挙 |
| M6b | 比較runnerと観測state、既存fixtureの接続 | 戻り値/状態/trap/NaN比較を独立期待値で検証 |
| M6c | 命令単位の不足fixtureと対象内修正 | 正常・境界・trapの必要な証拠が揃う |
| M6d | call/Store/EH/API/CLI/WASI複合試験 | 上表の経路で両runtimeの結果が揃う |
| M6e | 全構成検証、性能回帰、対応文書 | 未解消の対象内失敗が0、制限と証拠を公開可能な形に記録 |

M6eで初めて全テストを追加するのではなく、各修正時点で必要な構成を検証する。
既に通した試験の無理由な反復を避け、変更の影響範囲に応じて再実行する。

## 最終受け入れ条件

188命令すべてに必要な実行証拠があり、対象内の未実装・誤結果・不正なtrap/副作用が残っていない。
CRuby/Spinelの必須runでskipを成功とみなさない。環境依存のWASI/外部エンジン検証が実行できなければ未完了を明記する。
既存の `bundle exec rake test`、`bundle exec rake check`、`make spinel-test RUBY="bundle exec ruby"`と、新manifest runnerを実行する。
参照実装との差は、NaN許容差・旧VM既知不具合・対象外API等の根拠付き分類を持つ。

M4/M5とi32 baselineの性能を比較し、loadと実行を分ける。公開境界のboxingと内部dispatchを別に見る。
対応完了を高速化達成と混同しないが、新しい再現性のある退行は原因と対処/制約を記録する。
ドキュメントへ対象・追加EH・対象外・runtime差・API契約・再現コマンドをまとめ、完了時点のcommitとツールversionを記す。
「Wasm完全対応」ではなく「M0で定めた既存188命令への対応と、明記した拡張範囲の検証完了」と表現する。
