# ADR 0015: IRコピーの線形化とinline用snapshotの選別

- **状態** 提案（実装仕様）
- **日付** 2026-11-16
- **基準** 本体 `1de771d`、[性能調査](../efflorescence-mir-generation-performance.md)
- **必読** [実装担当向け入口・共通検証条件](../efflorescence-mir-generation-implementation.md)
- **関連** [inliningの実装記録](../efflorescence-inlining.md)

## 背景と決定

大入力のSpinel最適化は約1.045秒。詳細計測では `IR#copy` が2回、合計1.030秒で、最適化時間の約99%だった。現行はsemantic IRからoptimized IRへのコピーに加え、Inliningが全calleeのsnapshotとしてさらに全IRをコピーする。inline対象外の大関数もこの2回目に含まれる。

次の3変更を行う。

1. `Function#copy` のconstant membershipを一時bitmapで判定し、O(R×C)の走査をO(R+C)にする。
2. `Optimizer#optimize` の最初の全IR独立コピーは維持する。
3. `Inlining#run` のsnapshotはeligibleなcalleeだけに絞り、展開できるCALLがないcallerではRewriteを作らない。

コピーを省くためにinlineを無効化したり、閾値を下げたりはしない。最初の全コピーまでなくすcopy-on-writeやsemantic IRの遅延再生成は対象外。今回得られるのは主に2回目の全コピーの削減と、残るコピーのmembership走査の削減であり、最適化時間の99%全部が消える見込みではない。

## 対象と変更しない契約

- [ir.rb](../../lib/wardite/efflorescence/ir.rb): `Function#copy`。`IR#copy` の全体コピーAPIは残す。
- [optimizer.rb](../../lib/wardite/efflorescence/optimizer.rb): `Passes::Inlining#run` / `expand_calls` とその補助メソッド。
- [vm.rb](../../lib/wardite/efflorescence/vm.rb): 変更不要。semantic IRとoptimized IRは従来どおり独立する。

`Function#index` はimportを含むmodule index、`pool_index` はdefined functionの位置。callee表のキーは **module index** にする。`functions[call[2]]` で解決しない。

最初のIRコピーでは命令とoperand、register情報、handler/throw/memory/dynamicの各可変配列、entryの型配列が独立する。host callable/externalは現行 `HostFunction#copy` と同様に共有する。immutableな値の共有と、書き換えるMIR配列の共有を混同しない。

## A. Functionコピーのmembership bitmap

既存のconstructor、feature flagsコピー、side tableコピー、parameter/local以降を `allocate_register` / `allocate_constant` で再作成する手順、命令のdeep copyを残す。変更するのはconstant判定のみ。

```text
constant = Array.new(register_count, 0)
constant_registersを走査:
  0 <= r < register_count の要素について constant[r] = 1
index = parameter_count + local_count
while index < register_count:
  constant[index] == 1 なら allocate_constant(既存の値, 既存の型)
  それ以外は allocate_register(既存の値, 既存の型)
  index += 1
```

このbitmapはコピー1回だけの一時値で、Functionやキャッシュへ追加保存しない。入力constant listの順序・重複を前提にしない。範囲外値をbitmapへ代入するとRubyの負indexやArray拡張で挙動が変わるので、上記の範囲判定を入れる。コピーの責務で新たな検証は加えず、旧 `include?` と同じ「実在するindexとのmembership」にする。正規化された出力constant listの順序も旧コードと一致する。

`@initial_registers.dup` で全bankを置き換える案は採用しない。現行copyはconstructorでparameter/localの初期値を作り直すため、単純な全dupでは手書きIRで契約が変わり得る。bitmapのO(R)追加メモリとnative割り当てを測り、コピー後は保持しない。

## B. snapshotを作る時点と内容

`Optimizer#optimize` の順序を維持する。

```text
output = semantic.copy
outputの各関数に初回のoptimize_function
inlineがenabledなら:
  changed = Inlining.run(output)
  changedのmodule index順（現行の訪問順）にoptimize_functionを再実行
return output
```

`Inlining#run` の最初に全defined functionを1回見て、現行 `eligible?` がtrueのものだけをコピーする。

```text
candidates: Hash[Integer, Function] = {}
ir.functions.each:
  eligible?(function)なら candidates[function.index] = function.copy
```

全候補のコピーが終わるまでcallerを書き換えない。コピー元は **初回のローカル最適化が終わったoutput** であってsemantic IRではない。処理中に新しくeligibleになったmiddle関数を追加しない。これにより現行の1 round・非推移的なinliningを維持する。

candidateにはentry/host表のコピーは不要。`expand` が読むfunctionの型・初期値・constant・命令は従来どおりコピーで所有する。snapshotのfunction自体をcallerへ移動したり、展開中に変更したりしない。

`eligible?` の条件はそのまま使う。

- feature flagsによるi64/float/EH/store/dynamic除外。
- 命令数1〜8、register数32以下、末尾RETURN。
- 末尾以外は現行の明示的なopcode whitelistのみ。

CALL、再帰、branch、trap、PROFILE、unknown opcodeを新しく許可しない。whitelistや予算を別の場所へ重複定義せず、既存メソッド/定数を使う。

## C. callerの早期スキップとrewrite

callerのfeature gateも現行どおり。候補CALLの有無を調べる `expandable_call?` を追加し、書き換え前に軽いscanを行う。候補表が空でも、現在 `function_at` が拒否する不正CALLを黙って無視しない。

1. callerのCALLを命令順に見る。`ir.function_at(call[2])` 相当でdefined calleeの存在を確認する。indexが不正・hostを直接指す場合の旧例外を維持する。
2. `candidates[call[2]]` が存在し、以下のgrowth/register条件を予算0から満たせるCALLが見つかればscanを終え、現行と同じRewriteへ進む。
3. 最後まで見つからなければfalseを返す。命令配列・各Instruction・targetsに触れず、Rewriteや命令copyを作らない。`changed` に追加しない。

Rewriteへ進んだ場合は、元の命令順に全CALLを再確認し、candidate snapshotを使って現行の予算を消費する。

```text
growth = max(0, callee.parameter_count + callee.local_count
                + callee.instructions.size - 2 + (call[1] >= 0 ? 1 : 0))
registers = callee.register_count + (callee.local_count > 0 ? 1 : 0)
expand iff added_instructions + growth <= MAX_ADDED_INSTRUCTIONS  # 64
       and added_registers + registers <= MAX_ADDED_REGISTERS      # 256
```

上記growthはcleanup前の保守的な見積もり。実際に削除されるCOPY数で予算を緩めない。引数snapshot、非引数localの0初期化、callee registerの新規割り当て、戻り値COPY、void戻り値、呼び出し先のconstantは既存 `expand` を使う。

Rewriteのmark/emit/finish、CALL位置へ飛ぶbranchのremapは維持する。引数初期化の先頭が元CALLのtargetになる。`changed` は実際に1つ以上展開したcallerのmodule indexを、従来と同じ順に返す。初回でeligibleでなかったcallerが途中で小さくなっても、callee snapshotへは追加しない。

candidateがなくても、不正CALL検出のscanが必要なcallerは存在する。正常な巨大moduleでsnapshotが空のときも「全callerのscanがゼロ」になるとは要求しない。消すのは全IRのdeep copyと無意味なrewriteである。

## 複雑度と診断カウンター

Rはregister数、Cはconstant数、Iは命令数。AでFunctionコピーのregister部分をO(R×C)からO(R+C)へ。Bで2回目のコピー量を全関数の総R/Iから、eligible calleeの総R/Iへ変える。1回目の全コピーは残る。callerのpre-scanは最大O(I)を追加するが、展開しない場合はO(I)のdeep copy/remapを省く。

benchmark/test限定で次を数える。本番プロファイル機構やキャッシュ形式にカウンターを追加しない。

- `IR#copy` 回数: 通常のbuild_mirでは2→1（profilingなど別機能のcopyは別集計）。
- inline snapshotのfunction数、instruction数、register数: eligible集合と一致し、非eligibleのcopyは0。
- Rewriteを作ったcaller数と、実際にchangedになったcaller数。
- constant membershipの準備走査C回、register判定R−parameter−local回。registerごとの `include?` は0回。

## テスト

[inlining](../../test/efflorescence_inlining_test.rb)、[optimizer](../../test/efflorescence_optimizer_test.rb)、[MIR cache](../../test/efflorescence_mir_cache_test.rb)を拡張する。

| ケース | 確認する内容 |
|---|---|
| semanticとoptimizedの分離 | optimize/inline/lower後もsemantic fingerprint不変。optimizedの命令・register・side tableを書き換えても元へ漏れない |
| linear copy | constantなし/多数/順不同/重複、parameter/local/temporary、i64/float bit carrier、side tablesで旧copyの値と一致。param/local初期値の旧契約を維持 |
| module index | 先頭と途中にimportがあり、module indexとpool indexが違っても正しいcalleeを展開 |
| snapshot時点 | leaf→middle→callerの3段でmiddleだけ展開し、caller→middleは残る。関数順を変えても1 roundを維持 |
| snapshot所有権 | 複数callerが同じcalleeを使っても、最初の展開が次のcallee内容を変えない |
| early skip | CALLなし、対象外calleeのみ、予算に入らないCALLでInstruction/命令配列のidentity不変、changedなし。semanticからoutputへの独立コピーは依然存在 |
| old rejection | 不正module index・hostを指す直接CALLで候補表の欠落を理由に例外を消さない |
| 境界 | 8/9命令、32/33register、64命令/256register予算の境界、local0初期化、aliasする引数とresult、void、constant return、branch targetがCALLを指す |
| 適用除外 | trap・再帰・PROFILE・unknown opcode・i64・float・EH・store・dynamic callの現在の除外を維持 |

全部の設定で共通文書のIR正規化を比較し、生成bytecodeの完全一致を確認する。最初のコピーを除いたつもりで、mutableな命令だけ共有する実装はこのテストで拒否する。

## 実装段階と受け入れ条件

1. Aのみ: Function copyの同値テスト、constant数/レジスタ数を独立に増やすfixture、CRuby/native計測。bitmapのpeak RSSを記録する。
2. Bのみ: snapshotの構造カウンターと1 roundテスト。大入力でinline snapshot対象量と最適化割り当てが減る。
3. C: early skip、target remap、予算のテスト。CALLの少ないi32関数とCALL密度の高いfixtureの両方を測る。
4. 共通のtest/check/native/parity/cache/guest検証とbefore/after比較を完了する。

大入力で最適化phaseの中央値・割り当てが改善し、load全体とゲスト実行に再現する退行がないこと。inlineが実際に働く小関数でも同じ命令列を作ること。対象集合が空だから速いという1ケースだけで完了しない。`--mir-disable inline` ではsnapshot作成自体が0回のままで、他の最適化トグルも維持する。

## 代替案・互換性・取り消し方

semanticとoptimizedのFunction共有は、Lowererがbytecode・call site・flat handlerをinstallするため今回は採用しない。Function全体をfreezeする案も現在のpass APIと合わない。eligibleなleafが今は書き換わりにくくても、snapshotを参照共有だけにすることはせず、対象を絞ったdeep copyにする。

MIRの値・キャッシュ形式・CODE_VERSION・CLIに変更はない。退行した段階だけを戻せる。全部を戻す場合も、従来の `IR#copy` とInlining経路へ戻すだけでキャッシュ移行は不要。
