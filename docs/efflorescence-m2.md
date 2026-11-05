# Efflorescence M2: memoryとglobal

[ADR 0002](adr/0002-efflorescence-m2-memory-and-globals.md)に沿い、段階ごとに実装・検証する。
実行はflatのみ。意味MIRは検証・変換・表示用に保持する。

| 段階 | 状態 |
|---|---|
| M2a: 検査・byte境界・MemorySite・Opcode情報 | 実装済み |
| M2b: i32 global | 未実装 |
| M2c: i32 load/store | 未実装 |
| M2d: size/grow | 未実装 |
| M2e: init/copy/fill | 未実装 |
| M2f: 統合・外部比較・性能 | 未実施 |

M2aではM2命令の即値・型・indexを到達不能コードでも検査するが、命令の実行はまだ拒否する。
shared/memory64/custom page limits、memory 0以外の指定、data count不足、immutable global.setを拒否する。
MemorySiteはdeep copy、register read解析・置換、Inspectionの対象とし、uses_store関数は既存passと
双方向のinliningから保守的に除外する。通常i32関数の最適化とM1のEH除外規則は維持する。

範囲検査は`start <= bytesize`と`length <= bytesize - start`で行う。
0長でも末尾を越えたstartはtrapになる。メモリはbinary Stringとして生成する。
共有の定数式デコードを命令単位に変更し、即値に0x0bが含まれてもendと取り違えない。
active dataの範囲はEfflorescenceのStore生成前に検査する。
共有ローダーとMemoryの変更は旧VMの回帰テストでも確認する。
