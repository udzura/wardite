# ADR 0016: 世代番号によるcopy propagationのalias無効化

- **状態** 実装済み
- **日付** 2026-11-16
- **基準** 本体 `1de771d`、[性能調査](../efflorescence-mir-generation-performance.md)
- **必読** [実装担当向け入口・共通検証条件](../efflorescence-mir-generation-implementation.md)
- **実装計測** [前後比較と回帰検証](../efflorescence-generation-tagged-copy-propagation-results.md)
- **変更対象** [CopyPropagation#propagate](../../lib/wardite/efflorescence/optimizer.rb)

## 背景と決定

現行propagateは、destinationへ書くたび全registerのaliasを走査し、そのdestinationを参照するaliasを無効化する。block leaderでも全alias配列を作り直す。I命令、R registerでO(I×R)になり得る。

人工i32関数のN=256→2048でpropagateはSpinel 0.223→8.045 ms、CRuby 4.410→224.579 ms。Nが8倍なのに約36倍/51倍になった。これは大きなi32関数での問題であり、最適化対象がほぼないRuby Wasmの主因とは別。

**registerの更新世代とblock epochを使い、aliasを読むときに有効性を判定する。** 各destinationでの全走査とleaderでの配列再作成をなくす。命令書き換えの結果は現行と完全一致させる。

`coalesce_results`、`remove_overwritten_copies`、`remove_dead_copies`、Analysis、Rewrite、最適化対象のfeature gateや順序は今回変更しない。dead-copyのworklist化、Analysisの共有、グローバルなcopy propagation、SSAは別変更にする。

## 現行の意味と守る不変条件

1. blockをまたぐaliasは保持しない。leaderに入った時点で全registerは自分自身を指す。
2. 読み出しoperandを、その時点のalias先へ置換してからdestinationを書き込む。
3. destination `d` の更新は、`d` 自身のaliasと、値の出所が `d` だったaliasを無効にする。過去にコピーした値はそれぞれのregisterに残るため、無効なaliasは **自身のregister** へ戻る。
4. 書き換え後の `COPY d,s` で `d != s` のときだけ新しいaliasを記録する。通常の演算はdestinationを無効化するだけ。
5. aliasは記録時に解決済みのrootを指す。連鎖を後から再帰的にたどらない。

例: `COPY r1,r0; COPY r2,r1; WRITE r0` の後、r1/r2を新しいr0へ置換してはいけない。r1とr2に保存された古い値を読む。

## データ構造

propagate呼び出しごとに次をR要素で一度だけ確保する。Functionへ保存しない。全要素はIntegerで、Hash/Setやオブジェクトnodeは使わない。

| 名前 | 初期値 | 意味 |
|---|---:|---|
| `write_version[r]` | 0 | register rへの処理済み書き込み回数 |
| `alias_root[r]` | 0 | 有効なaliasがある場合の解決済みsource |
| `alias_source_version[r]` | 0 | aliasを結んだ時点のrootのwrite_version |
| `alias_epoch[r]` | 0 | このaliasを記録したblock epoch。0は明示的無効 |
| `epoch`（scalar） | 1 | 現在のblock。leaderで増加 |

`alias_root[r]` はalias_epochが有効な場合だけ意味を持つ。0初期化はr0へaliasがあるという意味ではない。leaderで配列をclear/fillしない。

世代は1回のpropagate中に最大I程度しか増えない。Spinelの既定オーバーフロー検査を残し、wraparoundやbit maskで巡回させない。実際のnative上限を超える規模を特別扱いする最適化は不要。

## アルゴリズム

以下を仕様とする。helperを新しい小クラスにする場合は `Passes::CopyAliases` とし、`resolve(register) -> Integer`、`write(destination)`、`bind(destination, source)`、`next_block` を持たせる。配列はprivateで、各メソッドの引数/返値をinline RBSで指定する。helper自体の1回の確保は許す。

```text
resolve(r):
  if alias_epoch[r] == epoch:
    s = alias_root[r]
    if alias_source_version[r] == write_version[s]:
      return s
  return r

next_block:
  epoch += 1

write(d):
  write_version[d] += 1
  alias_epoch[d] = 0

bind(d, s):                 # sはresolve済み、write(d)の後に呼ぶ
  if d != s:
    alias_root[d] = s
    alias_source_version[d] = write_version[s]
    alias_epoch[d] = epoch
```

命令ループは次の順序を厳守する。

```text
analysis = Analysis.new(function)
aliases = CopyAliases.new(function.register_count)
rewrite = Rewrite.new(function)
function.instructionsを元のPC順に走査:
  rewrite.mark(pc)
  analysis.leaders[pc] == 1なら aliases.next_block
  instruction = original.copy
  元と同じread positionの各pについて:
    instruction[p] = aliases.resolve(instruction[p])
  d = Opcode.destination(instruction)
  if d >= 0:
    aliases.write(d)
    if instruction[0] == COPY:
      aliases.bind(d, instruction[2])
  rewrite.emit(instruction)
rewrite.finish
```

read positionには、既存 `Opcode.read_positions` をそのまま使用できる。ADR 0014が先に入っていれば `Opcode.read_count` / `read_position` のcounted loopへ置き換える。callee index・immediate・branch targetへresolveを適用しない。CALLでは可変長引数をすべてresolveし、その後でresult destinationをwriteする。void CALLのdestination -1ではwriteしない。

元コードと同じくInstructionのcopyを作ってから書き換える。alias先を書き換える途中で新しいdestinationを書いてはいけない。各readは同じ更新前stateで解決する。

## なぜ連鎖をたどらなくてよいか

aliasを結ぶとき、sourceは既に現行stateで解決済みである。rootが後から新たな値を持つ／別のaliasへ結び直されるには、そのrootへの書き込みが必要なのでwrite_versionが増える。古いrootを持つaliasはversion不一致になり、自分自身へ戻る。

失効した `r -> old_root` を、`resolve(old_root)` へつなぎ直す処理は禁止する。rに保存されている古い値と、old_rootの現在値は違い得る。path compressionも必要ない。失効したaliasの配列内容はそのままでよい。

leaderのepoch不一致は現行の全aliasリセットと同じ効果になる。write_versionをblockごとに0へ戻す必要はなく、戻すと古いversionが偶然一致する設計事故を招く。

### 手で追える例

| 操作 | 期待する解決結果 |
|---|---|
| `COPY r1,r0` | resolve(r1)=r0 |
| 続けて `COPY r2,r1` | 命令はCOPY r2,r0。resolve(r2)=r0 |
| 続けて `WRITE r0` | resolve(r1)=r1、resolve(r2)=r2 |
| 続けて `COPY r3,r1` | resolve(r3)=r1。古いr0へ戻らない |
| 続けて `WRITE r1` | resolve(r3)=r3、r2には影響しない |
| 新しいblockへ入る | 全rでresolve(r)=r |

`COPY r1,r0; COPY r0,r1` は2命令目のsourceが先にr0へ解決され、COPY r0,r0になる。その後write_version[r0]を増やし、bindしない。これも現行アルゴリズムと同じ。

## 複雑度と境界

配列初期化O(R)、block切り替えO(1)、各read解決O(1)、各destinationのwrite/bind O(1)。propagateのalias管理は **O(R + I + 読み出しoperand総数)**、メモリO(R)。root chainの長さに依存しない。

AnalysisとRewriteは既存のままなので、optimizer全体や他のcopy subpassまで線形になったとは主張しない。たとえばremove_overwritten_copiesのblockごとのlive.fillやdead-copyの反復は残る。診断timeは `propagate` と `copy_pass` と最適化全体を分ける。

4本のInteger配列は従来1本より大きい。大R・少命令のケースも測り、ピークRSSを確認する。実測なしに世代番号を1つのIntegerへbit packしない。

## テスト設計

[optimizer](../../test/efflorescence_optimizer_test.rb) と [inlining](../../test/efflorescence_inlining_test.rb) を拡張する。旧propagateをtest/supportの参照実装として保存し、同じ入力MIRの独立コピーへ新旧を適用する。本番には旧方式のCLI flagを追加しない。

1. 上記の各alias連鎖・root上書き・alias先ではないregisterの上書き・self COPY・COPYのsource/destination重複を、書き換え後の全operandまで比較する。
2. `ADD r1,r1,r2` のような同一命令内read/write、同じsourceを2回読む命令、readなしのwrite、destinationなしのRETURN/branch、void/direct CALLと多引数CALL。
3. leader直前のalias、branch先への飛び込み、diamond、loop/backedge、unreachable block。Analysisが設定した全leaderでリセットされる。
4. constant、parameter、local、temporaryを混在させる。複数回propagateを呼んでも配列stateが漏れない。inline後に再最適化されたcallerでも一致する。
5. deterministic random test: seed `20261115`、register数1〜32、100操作×10,000列。COPY、通常write、read、leaderを混在し、各操作の全registerの解決結果を旧方式と比較する。これはhelperの状態機械の比較であり、Wasm実行の代わりにはしない。
6. 有効なMIRでもseed固定の生成を行う。readsが定義済みになるよう生成し、新旧のInstruction/targetsの完全一致、RegisterValidation、複数入力の実行結果を確認する。不正MIRに新方式が検証済みのふりをしないことも既存拒否テストで確かめる。

設計時には上記5相当の抽象状態機械をPythonで100万遷移比較し、一致を確認した。また、COPY・ADD・ADD_IMM・EQZ・BR_IF・RETURNからなる1,000個のMIR関数に、現行propagateと上記の配列操作をRuby上で適用し、全operandとtargetの一致を確認した（同じseed）。製品用helper・ゲスト実行・Spinelでの検証ではないため、実装時に回帰テストへ移植する。既存のEH・i64・float・store/dynamic除外は維持し、対象外関数へこの方式を新規適用しない。

## 性能と受け入れ条件

test/benchmark限定で `resolve`、`write`、`bind`、`next_block` の回数、R要素配列の初期化回数を数える。destinationごとのR走査とleaderごとのR要素再初期化が0であること。これは処理回数の検証であり、各操作へ時計を入れたtimeを性能の根拠にしない。

既存 `generate_mir_generation_fixtures.rb` のN=256/512/1024/2048に4096/8192を追加して、新旧を共通条件で計測する。さらにblock数を増やすfixture、同一rootを何度も上書きするfixture、長いCOPY連鎖、多引数CALLを追加する。

- 各サイズで生成MIR/flat codeは旧方式と完全一致する。
- N=2048以上のpropagate中央値が新旧比較で改善し、構造カウンターも線形な処理量を示す。大きい2点でN倍増時のtime増加が3倍を超える場合は、GC・Analysis・Rewriteの費用と区別して調べ、aliasの二次走査が残っていないことを示す。
- 小入力・大R少命令・Ruby Wasmで共通の退行基準を満たす。対象外の大入力で目立つ短縮を要求するのではなく、余分な初期化・RSS増加がないか確認する。
- 全test/check/native/parity/cache/guest検証を通す。MIR不変なのでCODE_VERSIONは変えない。

## 実装順と取り消し方

1. 旧方式のtest-only参照、手書きケース、helperの状態機械テストを作る。
2. CopyAliasesを実装し、propagateのalias管理部分だけ差し替える。AnalysisとRewriteに手を入れず完全一致を確認する。
3. native型・性能・RSS・構造カウンターを確認し、生データを記録する。

逆aliasの連結リストは別案だが、root上書きのたびにalias数だけ走査する必要がある。世代方式ならその走査も不要であり、今回はこちらを採用する。世代方式がnativeで退行するなら、別案を黙って混ぜず結果を記録してADRを改訂する。

変更はFunctionにstateを残さない内部passなので、propagateを元に戻すだけで取り消せる。キャッシュ・VM・公開APIの移行は不要。
