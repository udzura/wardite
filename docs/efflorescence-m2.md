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
| M2f: 統合・外部比較・性能 | 未実施 |

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
