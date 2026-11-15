# ADR 0014: MIR生成時の検証・デコードの走査と割り当てを減らす

- **状態** 実装済み
- **日付** 2026-11-16
- **基準** 本体 `1de771d`、[性能調査](../efflorescence-mir-generation-performance.md)
- **必読** [実装担当向け入口・共通検証条件](../efflorescence-mir-generation-implementation.md)
- **実装計測** [前後比較と回帰検証](../efflorescence-mir-build-validation-and-decoding-results.md)
- **関連** [ADR 0007](0007-efflorescence-ruby-wasm-phase1.md) の検証契約

## 背景と決定

Ruby 3.4.2 WasmのSpinel計測で、load全体11.513秒のうちレジスタ検証4.200秒、セクションデコード3.012秒、feature確認0.920秒。CRuby診断では検証約3,086万、デコード約2,249万オブジェクトを割り当てた。時間とオブジェクト数は別ランタイムの測定である。

検証を省略せず、(A) 配列を返さないoperand参照、(B) EHなしの関数にブロック単位のCFG、(C) byte読み出しと共有opcode仕様、(D) decoderが所有するfeature情報、をこの順に導入する。各段階を独立して検証する。

Wasm命令配列とsemantic MIRの表現は維持する。Wasm→MIR直接変換、SSA、レジスタ詰め直し、EHの新しいdataflow、block use/def summaryによる固定点処理の変更は今回の対象外。まず同じ検査を少ない割り当てで行う。

## A. 配列を作らないレジスタ参照

対象は [ir.rb](../../lib/wardite/efflorescence/ir.rb)、[optimizer.rb](../../lib/wardite/efflorescence/optimizer.rb)、[register_validation.rb](../../lib/wardite/efflorescence/register_validation.rb)。追加する内部API:

```text
Opcode.read_count(instruction) -> Integer
Opcode.read_position(instruction, ordinal) -> Integer
Function#read_count(instruction) -> Integer
Function#read_at(instruction, ordinal) -> Integer
```

`Opcode` の2メソッドは命令内のoperand位置を、`Function` は実際に読まれるregister番号を扱う。ordinalは0始まりで、count未満に限る。範囲外は既存のfetch相当の例外にし、黙って0を返さない。

1. 固定operand位置は、既存 `Opcode.read_positions` のcaseを元にopcodeごとの読み取り専用表へ移す。表の配列は実装内で共有し、外へ渡さない。未知opcodeの既存の拒否を維持する。
2. `CALL` は `3...instruction.size`（countは `max(0, size - 3)`）、`RETURN` は負のresult registerなら0件、それ以外は位置1。これらを固定表で扱わない。`CALL_INDIRECT` の命令内readは位置3。
3. Function側は命令内readに続けて、現行 `Function#reads` と同じ順でTHROWのpayload、memory siteのsources、dynamic siteのargumentsを返す。同じregisterが複数回出たら省かない。callee/module/table indexはregisterではない。
4. `reads` と `read_positions` は互換adapterとして残し、上記APIから**新しい配列**を作って返す。mutableな戻り値という契約を変えない。
5. `Analysis`、検証の型確認・definite assignmentをcount＋while loopへ移す。型チェックのread数・順序、side tableの存在とindex検査を先に行う順序を維持する。他の既存呼び出し元は段階的に移せる。

特に [MIRCache::Decoder::REGISTER_MASKS](../../lib/wardite/efflorescence/mir_cache.rb) は `positions << 1` を行う。既存APIを共有frozen配列へ置き換えてはいけない。キャッシュをrequireするだけで共有表を書き換えたり例外になったりするためである。

Spinelで計数・添字を固定幅Integerに保つ。Enumeratorや命令ごとのclosure・一時Arrayを返す設計にしない。固定表と互換adapterに同じopcode分類を二重に手書きしない。

## B. 非EHのブロックCFG

### 選択条件

`RegisterValidation#validate` はempty判定と `validate_types` をこれまでどおり全命令へ実行する。その後、次をすべて満たすときにだけ新しい `validate_plain` 経路へ入る。

- `uses_eh == false`、handlersとthrow_sitesが空、register_typesに`:exnref`がない。
- 全命令を確認して `EH_ENTER` / `EH_TRIM` / `THROW` / `THROW_REF` / `COPY_REF` がない。

flagsだけでは手書き・不正MIRに対して十分ではない。実命令の確認はleader作成の走査にまとめる。どれかが該当すれば既存のFlowGraphとEH検証へ戻す。memory・i64・float・host/indirect CALLは、上記条件を満たせばplain経路でよい。handlerがないCALLの例外は関数外へ出るため、関数内の例外辺はない。

### データ構造と生成手順

`RegisterValidation::Block` のfirst、limit（exclusive）、defined、pending、successorsを再利用する。新経路では `Analysis` や命令単位の `FlowGraph` を生成しない。

1. `leaders: Array[Integer]` を命令数Iだけ0初期化し、PC 0をleaderにする。
2. 全命令について `Opcode.target_position` を使い、branch targetを `0 <= target < I` で検査しleaderにする。branchを持つ命令、terminal命令の直後も、I未満ならleaderにする。到達不能命令のtargetも検査する。
3. leader順に `[first, limit)` のblockを作り、`block_for_pc: Array[Integer]` を埋める。命令ごとにArrayを作らない。
4. 各block末尾の命令からsuccessorsを作る。targetがあればそのblockを先に追加。terminalでなく次の命令がI未満ならfallthrough先を追加。既存と同じ辺の順序・重複を保つ。通常のblock内のfallthroughは格納しない。
5. block 0から明示stackのDFSでreverse postorderを作る。Rubyの再帰を使わない。到達したblockでsuccessorsが空、かつ末尾がnonterminalなら既存と同じfallthroughエラーにする。

手順5の条件を独断で強化しない。現行 `FlowGraph` は「到達可能で正常後続が空、かつ非terminal」を拒否している。たとえば末尾conditional branchの新しい検証規則を加えるなら、性能変更と分ける。

`reverse_postorder` のうち「successorsを作る処理」と「既存successorsをDFSする処理」を分離し、後者を `block_reverse_postorder(blocks)` として共用する。EH経路では今までどおりinstruction flowからsuccessorsを作ってから呼ぶ。

### definite assignment

現在の32bit word配列、`Block#merge` の初回copy・以後intersection、RPOでpending blockを再処理する順序を維持する。入口は引数・local・定数が定義済み。block内は次の順:

1. AのAPIで全readを列挙して定義済みか検査。
2. destinationがあれば、既存の範囲・定数書き込み検査を行い、定義済みにする。
3. blockの正常後続へmerge。変更があればpendingへ戻す。

plain経路では命令ごとのexceptional配列参照だけを除く。CALLの引数をresult destinationより先に読む。到達不能コードの型・index検査はAの `validate_types` に残る。定義前readやdestinationへの定数書き込みなど、現行が到達経路で実行する検査の適用範囲は変えない。

追加CFG構築は O(I + B + E)、命令単位の空Arrayは0個。保持する整数vectorはleader・block_for_pc、辺はblock単位。dataflowのbitsetメモリ O(B×ceil(R/32)) と反復回数は現行と同じで、全検証が線形になるとは主張しない。

## C. byte読み出しとopcode仕様

対象は [load.rb](../../lib/wardite/load.rb)、[leb128.rb](../../lib/wardite/leb128.rb)、[instruction.rb](../../lib/wardite/instruction.rb)。

- opcode・u8・catch kind・LEB128の読み出しを `read(1).ord` から `getbyte` へ移す。File/StringIO両方でInteger/nilを扱う。0をEOFと扱わない。EOF時の既存例外を保ち、`readbyte` のEOFErrorをそのまま外へ漏らさない。
- fixed-widthのf32/f64、名前、dataなどの一括String読み出しは維持する。浮動小数点のbit patternは変換しない。
- unsigned LEB128のlevel・幅検査、signedの終端padding検査を移植する。signedで `bytes` を蓄積して符号拡張済み値から逆順に組み立てる部分は残す。10byte i64をunsigned 70bit値へ組み立てる改変はSpinelのoverflowを起こすため行わない。
- s33 blocktypeのbyte数判定は `StringIO#pos` の差を維持する。多byteの負value/voidを受理しない。

opcodeごとの読み取り専用 `DecodeSpec(namespace, code, operand_types)` を起動時に一度だけ作る。通常opcode表と0xfcのsubopcode表を分け、後者のindexは従来どおりULEB128で読む。namespaceは現行 `NAMESPACES` / `FC_OPERANDS` と同じ値を使う。hot loopは共有specを参照し、解決用3要素tupleを毎命令生成しない。

`Op.operand_of` は互換性のためfreshなArrayを返すadapterとして残し、decoderは共有specのoperand_typesを直接読む。既存 `resolve_code(String, buf)` も必要な呼び出し元用のadapterとし、hot loopから外す。全opcodeのspecと旧resolver結果を比較するテストを追加する。unknown opcode/prefixは既存の拒否経路へ渡し、無視・読み飛ばし・別命令への置換はしない。

## D. feature確認用の情報と所有権

全operandの再走査を省くため `DecodedBody` を追加する。これはWasmの命令表現自体の置換ではなく、decoder内の返却用オブジェクト:

```text
instructions: 現行の5要素tupleのArray
blocks: Array[Wardite::Block]  # 出現順、instructions内と同じBlock参照
has_eh_instructions: bool     # try_table / throw / throw_ref のいずれか
```

`BinaryLoader.decode_body(buf) -> DecodedBody` に現在の実処理を移す。block operandを作った時点でblocksへ追加し、EH opcodeを読んだ時点でflagを立てる。else/end位置を確定する既存の構造化制御の処理はそのまま行う。既存 `code_body(buf) -> instructions` はadapterにし、global初期化式などの利用者の型を変えない。

CodeBodyにはprivateの `install_decoded(decoded)` とsummaryを追加する。decoderの返したArray/Blockを外部が保持したままinstallできる公開APIにはしない。eager用の `CodeBody#decode_from(buf)` が内部でdecode_bodyを呼び、結果をprivate installerへ渡す。CodeBodyからsummaryのgetterも公開しない。経路は次のとおり。

| 経路 | feature確認 |
|---|---|
| eager decode | `read_function_body` がCodeBody#decode_fromを呼び内部でdecode→install。Instanceで後からsummaryを検査 |
| cache missのdeferred decode | `check_features` 内でdecode_body。summaryの検査成功後にbodyを確定しbytesを消す |
| cache hit | bytesを保持し、従来どおり検査・decodeを強制しない。inspectionで初めてbodyが要求された時は上のdeferred経路 |
| 手書き `body=` / summary無効後 | 現行check_instructionsの全走査へfallback |

summary検査ではlocalのexnref拒否、stack engineのEH拒否、blocksのtype_index解決、indexed/reference block signatureのstack拒否を維持する。型sectionの存在・index範囲を各blockで調べ、`Block#resolve` で命令内の同じBlockを更新する。

**公開bodyはmutableである。** `body=` はsummaryを必ず破棄し、外部配列からtrusted summaryを作らない。`body` getterは必要な遅延decode/検査を完了したあと、返す直前にsummaryを破棄する。返したArray/Blockを利用者が変更しても、次のcheck_featuresは全走査になる。`instruction_bytes=` もsummaryを破棄する。この無効化なしにblocks/flagsをmemoizeしてはいけない。summaryは初回ロードの内部所有期間だけの高速化でよい。

この経路で変更するのは初回確認の対象数 O(I + operand数) → O(block数)。関数ごとのsummary・block参照配列の費用も計測する。

## テストと段階ごとの受け入れ条件

| 段階 | 必須ケースと構造条件 |
|---|---|
| A | 全opcodeとvariable arity CALL、void RETURN、THROW/memory/dynamic side operandsで旧readsと順序・重複まで一致。互換配列を変更しても共有表が変わらない。MIRCacheをrequireしてREGISTER_MASKSが一致。hot read APIが命令ごとの配列を生成しない |
| B | linear・diamond・loop/backedge・self-loop・重複辺・到達不能block、範囲外target、末尾fallthrough、定数dst、64個超register。plain関数ではFlowGraph構築0回。EH opcodeをflags=falseに偽装しても旧経路へ入る |
| EH回帰 | nested handler、EH_TRIM、handler stack不一致、CALLの正常結果とcatch payloadの違い、THROW_REF、unreachableの不正型。既存の受理/拒否が一致 |
| C | File/StringIO、byte 0、EOF、u32上限・超過、i64最小最大・10byte・padding・continuation、s33、float NaN payload、0xfc、memarg、catch header、構造化制御。decoded tuple/Blockを旧実装と値比較 |
| D | eager/deferred/cache hit/inspection、stack/Efflorescence、body=での置換、getterで取得した配列やBlockの変更後の再検査。不正block indexとEHを注入してもsummary経由で検査を回避しない |

既存の [register initialization](../../test/efflorescence_register_initialization_test.rb)、[loader](../../test/efflorescence_m1_loader_test.rb)、[LEB128](../../test/leb128_test.rb)、[MIR cache](../../test/efflorescence_mir_cache_test.rb) を拡張する。追加のplain CFG/read APIテストは `test/efflorescence_register_validation_test.rb`（新規）へ集める。旧validatorとの比較実装はtest/support限定に置き、本番CLIへ選択肢を増やさない。

性能の合格条件は共通文書に加えて、B後に大入力の検証割り当てと検証timeが減ること、C/D後にデコード＋feature確認の合計timeとデコード割り当てが減ること。Dの評価でデコードへ移動した費用を省いてfeature時間だけ比較しない。EH関数のtime/RSSも計測し、Aの共有変更による退行がないことを確認する。パーサーを触るためstack VMの回帰も必須。

## 代替案と取り消し方

全CFGを一気に作り直す案はEHの辺固有定義を壊す危険があるため採用しない。block use/def summaryは反復走査を減らせるが追加bitsetとエラー位置の設計が必要なので、B後のプロファイルで改めて判断する。直接Wasm→MIR変換は共有loaderとの責務変更になるため別ADRとする。

各段階が退行すればその段階だけを戻す。Aの互換adapter、BのEH経路、Dの全走査fallbackを残すので、生成形式やキャッシュの移行をせず取り消せる。
