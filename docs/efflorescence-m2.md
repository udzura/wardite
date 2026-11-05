# Efflorescence M2: memoryとglobal

[ADR 0002](adr/0002-efflorescence-m2-memory-and-globals.md)に沿い、段階ごとに実装・検証する。
実行はflatのみ。意味MIRは検証・変換・表示用に保持する。

| 段階 | 状態 |
|---|---|
| M2a: 検査・byte境界・MemorySite・Opcode情報 | 実装済み |
| M2b: i32 global | 実装済み |
| M2c: i32 load/store | 実装済み |
| M2d: size/grow | 実装済み |
| M2e: init/copy/fill | 実装済み |
| M2f: 統合・外部比較・性能 | 検証済み |

M2命令の即値・型・indexは到達不能コードでも検査し、M2の15命令をflatで実行する。
shared/memory64/custom page limits、memory 0以外の指定、data count不足、immutable global.setを拒否する。
MemorySiteはdeep copy、register read解析・置換、Inspectionの対象とし、uses_store関数は既存passと
双方向のinliningから保守的に除外する。通常i32関数の最適化とM1のEH除外規則は維持する。

範囲検査は`start <= bytesize`と`length <= bytesize - start`で行う。
0長でも末尾を越えたstartはtrapになる。メモリはbinary Stringとして生成する。
共有の定数式デコードを命令単位に変更し、即値に0x0bが含まれてもendと取り違えない。
active dataの範囲はEfflorescenceのStore生成前に検査する。
共有ローダーとMemoryの変更は旧VMの回帰テストでも確認する。

M2bではi32 global.get/setを実装した。Global.valueを状態の保持元として、get時は
正規化整数を一時レジスタへ読み、set時だけI32へboxingする。
関数呼び出し・再帰を挟んでも既に読み込んだ値は変わらず、更新は公開callを越えて同じinstanceに残る。
使用しないi64/f32/f64 global宣言は維持し、非i32アクセス・immutable set・型不一致を拒否する。

M2cはlittle endianの5種類のloadと3種類のstoreに対応する。
狭幅signed loadは符号拡張後にi32へ正規化し、storeは指定幅の下位bitだけを書き込む。
effective addressはunsigned address + static offsetをwrapせずに計算する。
未整列アクセスを許し、storeは全範囲を検査してからsetbyteする。
失敗時にmemory内容・bytesize・currentは変わらず、読み捨てるloadのtrapも維持する。

M2dではsize/growを実装した。growは宣言maxと65536ページの上限を先に確認し、
新しいbinary bufferを用意してからdata/currentを更新する。失敗はunsigned i32の0xffffffff。
delta=0ではbufferを再作成しない。割当境界のNoMemoryErrorだけを失敗値へ変換し、
その他のRubyエラーは伝播する。CRubyで割当失敗を注入して状態維持を確認する。
Spinelの実プロセスOOMからの回復は保証・検証しない（巨大割当は行わない）。

M2eではStoreにinstanceごとの実行時data segmentを持たせる。
passiveは複製したbinary String、activeは共有初期化の後は空のsourceとして扱う。
copy/initはsource/destinationの両範囲を検査してから独立したbyte列を転送し、
fillはvalue & 255を用いる。0長でも両endpointを検査し、失敗でStringを拡張・縮小しない。
data.dropはデコード後も明示拒否する。

## 統合と受け入れ条件

Storeがmemory/global/runtime data segmentの唯一の保持元である。
同一instanceの更新は公開callを越えて残り、別instanceは独立する。
startとactive dataの初期化、memory/global exportは共有Store/Exportsを使う。
load/global.getは読んだ時点の整数を保持し、calleeでの更新やgrow後も値を取り違えない。

M1の明示的handler/frame操作を維持し、store/global.setの完了後にthrow・trapが起きても
更新を巻き戻さない。memory trapはcatch_allを通らない。未捕捉例外・trapの後も
同じVMへ再callでき、再利用Frameのlocalは初期化される。

MemorySiteは3つのsource registerとmemory/data indexを持ち、runtime値は書き込まない。
Function.copy、read解析、register置換、型/定義検証、Inspection、profilingに対応する。
Store命令を含む関数は既存passと双方向のinliningから除外するが、validation、flat、
profiling、framesは常に利用できる。Storeを使わないi32関数の既存最適化は継続する。

対応範囲はmemory 0、memory32、非shared memory、i32アクセスとglobal。
import・WASI・call_indirect・data.drop、multi-memory、memory64、threads/atomic、
他の数値型のアクセスと参照global保存は対象外。
範囲・即値・alignment・型・index・data countは外部validatorに任せずに検査する。
共有ローダー全体を完全なWasm validatorにする変更ではない。

## 検証（2026-11-05〜06）

```sh
bundle exec rake test
bundle exec rake check
make spinel-test RUBY="bundle exec ruby"
bundle exec ruby -Ilib benchmark/validate_m2.rb
```

- CRuby: 195 tests / 13,211 assertions、失敗・エラーなし。native専用58件は別実行。
- Steep: 生成RBSを含めて成功。
- Spinel: 58 tests / 2,462 assertions、失敗・エラー・省略なし。
- default、all無効、frames無効、profilingを両runtimeで確認。M1のEH・既存i32テストも実行する。
- 全幅の符号・byte順・切り詰め・未整列・末尾・1byte超過・2^32超過offsetを検査。
  store/bulkの失敗前後でmemory全体・bytesize・currentのsnapshotを比較する。
- 通常ケースは独立した旧VM/新VMのmemory全体・ページ数・global値を比較する。
  旧VMの境界store/bulk/active segmentの挙動を正解として使わない。
- Wasmtime 49.0.0 (`17830bd3c`, `-W exceptions=y`)、wasm-tools 1.218.0を使用。
  `validate_m2.rb`は37個の正常ケースでmemory全byteを順序付きFNV checksumへ含め、
  ページ数・i32 globalとともに比較する。戻り値も固定期待値で検査する。
  別に10個のmemory trapと1個の未捕捉Wasm例外を比較する。
  checksum比較はbyte単位snapshotの代わりにせず、後者は上のunit/nativeテストで行う。
- 参照した実行規則は[WebAssembly/spec `859d3232a55cdbb9d75343a072b05cd0a2172e1a`](https://github.com/WebAssembly/spec/blob/859d3232a55cdbb9d75343a072b05cd0a2172e1a/document/core/exec/instructions.rst)。

Spinelのnative API probeでは、iterator内のspecialized引数配列を渡す境界でVMの型を
具体化するhelperを用いる。汎用receiverだとcompilerがpolymorphic dispatchから
call_unboxedを落とすケースがあるためで、Warditeの公開APIは変更しない。
Spinelのinline RBS非適用等の既存warningは残る。実プロセスOOMからの回復は検証対象外。

## 性能記録

比較元はM2導入前の`8feb065`。macOS 27.0.1 / arm64、CRuby 4.0.9（YJITなし）、
Spinel 2026.10.25+1968 (`6f1a2c259`、任意のfetch-root削減パッチを含むローカルcompiler)で測定した。
同じcompilerをbefore/afterに使用し、`--strict-require -O2`、整数overflowチェックは既定のまま。
各caseはwarmup 2回＋測定7回、seed=123。before/afterまたはruntimeの順を交互に反転した。
ロードには読み込み・変換・最適化・検証・loweringを含み、実行には1回の公開呼び出しとFramePool生成を含む。
プロセス起動時間を含まない。checksumは全サンプルで独立期待値と一致した。

### 既存i32経路

`inline_mix`、`call_mix`とcall arityケースを比較した。callを残すため`inline`だけを無効にし、
framesを有効にする。M2でも通常ALU dispatchにStore型判定・handler探索・状態のキャッシュを加えない。

```sh
spinel -I BEFORE/lib --strict-require -O2 BEFORE/benchmark/call_cost_worker.rb -o /tmp/m2-before
spinel -I lib --strict-require -O2 benchmark/call_cost_worker.rb -o /tmp/m2-after
RUNS=7 ROUNDS=1000000 bundle exec ruby benchmark/measure_m1.rb /tmp/m2-before /tmp/m2-after
```

CRubyは`ruby --disable-yjit -I REVISION/lib REVISION/benchmark/call_cost_worker.rb "$@"`という
shell wrapperを各revisionに用意し、同じscriptを`ROUNDS=100000`で実行した。
時間の単位はms。実行はmedian (min–max)、ロードはmedian。

#### Spinel（1,000,000 rounds）

[全サンプル](../benchmark/results/efflorescence-m2-i32-spinel.json)。

| case | 実行 before | 実行 after | ロード before | ロード after | checksum |
|---|---:|---:|---:|---:|---:|
| inline_mix | 31.150 (30.937–31.438) | 31.069 (30.995–31.321) | 0.397 | 0.394 | 1259766978 |
| call_mix | 60.206 (58.153–65.256) | 61.370 (60.624–64.463) | 0.442 | 0.440 | 1259766978 |
| empty_loop | 10.734 (10.689–10.849) | 10.864 (10.837–10.900) | 0.622 | 0.632 | 123 |
| call_zero | 43.188 (42.886–49.612) | 44.722 (42.314–46.546) | 0.631 | 0.650 | 7000123 |
| call_one | 37.652 (37.049–38.013) | 36.951 (35.969–41.236) | 0.656 | 0.632 | 123 |
| call_two | 48.689 (48.285–50.334) | 49.711 (48.918–51.063) | 0.626 | 0.652 | 1000123 |
| call_three | 57.958 (56.706–70.706) | 58.388 (56.814–59.568) | 0.625 | 0.635 | 3000123 |
| call_four | 65.425 (63.746–68.651) | 65.531 (64.551–70.059) | 0.630 | 0.644 | 6000123 |

#### CRuby（100,000 rounds）

[全サンプル](../benchmark/results/efflorescence-m2-i32-cruby.json)。

| case | 実行 before | 実行 after | ロード before | ロード after | checksum |
|---|---:|---:|---:|---:|---:|
| inline_mix | 61.779 (60.409–66.187) | 60.749 (60.107–62.357) | 0.731 | 0.798 | 3870791521 |
| call_mix | 105.737 (103.801–109.281) | 107.328 (105.382–108.542) | 0.727 | 0.794 | 3870791521 |
| empty_loop | 19.073 (18.390–20.338) | 19.245 (18.089–21.294) | 1.388 | 1.567 | 123 |
| call_zero | 73.199 (71.338–74.104) | 72.663 (71.754–75.329) | 1.408 | 1.511 | 700123 |
| call_one | 62.459 (60.966–64.720) | 62.562 (61.842–64.344) | 1.424 | 1.515 | 123 |
| call_two | 80.208 (79.121–83.771) | 80.489 (79.460–81.217) | 1.449 | 1.525 | 100123 |
| call_three | 95.568 (94.306–98.461) | 96.778 (94.823–99.743) | 1.441 | 1.528 | 300123 |
| call_four | 108.962 (107.566–110.341) | 107.417 (105.580–110.337) | 1.433 | 1.618 | 600123 |

実行medianの差は全caseで-1.9%〜+3.6%。
新しい型/index/MemorySite検査と状態初期化のロードコストは別列に記録した。
この範囲で大きな非memory経路の退行は確認していない。単発の値で高速化を主張しない。

### M2の小さなworkload

```sh
RUNS=7 WARMUPS=2 ROUNDS=1000 bundle exec ruby benchmark/measure_m2.rb
```

`array_scan`は256ワードを初期化し、1 roundごとに全体を走査する。
`copy_fill`は256byteのfillと128byteの前方重複copy、`global_update`はglobalの更新、
`segment_init`は16byteのpassive初期化を繰り返す。各サンプルは独立プロセス・独立instance。
同じround数でもcaseごとの仕事量は異なる。[全サンプル](../benchmark/results/efflorescence-m2-memory.json)。

| case | runtime | ロード median | 実行 median (min–max) | checksum |
|---|---|---:|---:|---:|
| array_scan | CRuby | 0.767 | 266.528 (263.370–267.299) | 64128000 |
| array_scan | Spinel | 0.309 | 18.103 (17.603–19.340) | 64128000 |
| copy_fill | CRuby | 0.745 | 1.953 (1.894–2.048) | 127908 |
| copy_fill | Spinel | 0.311 | 119.775 (118.649–145.031) | 127908 |
| global_update | CRuby | 0.803 | 0.731 (0.714–0.794) | 1664525123 |
| global_update | Spinel | 0.302 | 0.039 (0.037–0.041) | 1664525123 |
| segment_init | CRuby | 0.782 | 1.745 (1.712–1.930) | 70099 |
| segment_init | Spinel | 0.307 | 60.265 (59.948–60.973) | 70099 |

Spinelの小さいbulk転送はCRubyより遅い。生成Cではcopy/fill/initのString範囲代入が
`sp_str_splice_at`へlowerされ、現在のruntimeはhead/tailと連結結果を作るため、転送部分以外にも
メモリ全体に比例するコピー・割当コストが発生する。M2の初期実装ではこの制約を記録し、
範囲事前検査・独立source・trap時の状態維持を保つ。専用bulk helperやfusionの解禁は
ADRどおり別の測定・レビューで扱う。M2の完了条件に高速化率は含めない。
