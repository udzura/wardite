# Efflorescenceのglobal整数配列化

VMはglobalの値をレジスタと同じ整数表現で保持する。公開関数とstart関数の入口、ホスト呼び出しの前後、実行を抜けるときに `Store` と同期する。書き戻しではビット列が変わった値だけをbox化する。[ADR 0011](adr/0011-efflorescence-unboxed-globals.md)

globalを持たないモジュールでは、VMの初期化時の判定で同期を省く。

## 計測環境

2026-11-12にApple M3 Pro、macOS 27.0.1 arm64で計測した。変更前はWardite `94a60e566a7349092697c9a5efabe3e5afbeb062`。Spinelの両バイナリはCIと同じ `6e7fc1355` にリポジトリのIO::Bufferパッチ2件を当てたコンパイラで `-O2` ビルドし、既定の整数overflowチェックを使った。CRubyは4.0.9。

## Ruby 4.0.9 Wasm

同じWasmで `--disable-gems -e 'puts RUBY_DESCRIPTION'` を実行した。SpinelとCRubyのMIR2キャッシュをそれぞれ変更前のバイナリで作り、全構成のウォームアップを1回行った。構成ごとに新規プロセスで5回計測し、反復ごとに実行順を反転した。各回でキャッシュヒットを確認し、標準出力をWasmtimeと照合した。ゲスト実行時間はプロセスの経過時間から `load_from_buffer` を引いた値。OSのファイルキャッシュはウォーム。

| ランタイム | ゲスト実行の中央値と範囲（秒） | プロセス全体の中央値（秒） |
|---|---|---|
| Spinel | 0.710（0.695–0.716） → 0.540（0.534–0.558）、23.9%短縮 | 1.225 → 1.065 |
| CRuby | 10.954（10.839–11.251） → 10.448（10.356–10.531）、4.6%短縮 | 12.146 → 11.648 |
| CRuby + YJIT | 7.456（7.418–7.527） → 7.319（7.242–7.515）、1.8%短縮 | 8.258 → 8.122 |

```sh
baseline_dir=$(mktemp -d)
git archive 94a60e5 | tar -x -C "$baseline_dir"
make -C "$baseline_dir" spinel
make spinel
RUNS=5 WARMUPS=1 ruby benchmark/measure_ruby_wasm_cache_hit.rb \
  "$ruby_wasm" "$baseline_dir" "$baseline_dir/build/wardite" build/wardite
```

## 小規模ベンチマーク

`measure_m4.rb` で既存のi32・i64・float・callの入力を実行した。i32とcallは10万回、i64とfloatは2万回のループを使い、各構成でウォームアップ2回、計測11回。各サンプルの結果をWasmtimeまたは既知のchecksumと照合した。

Storeは `i32_memory.wat` と `call_cost_worker.rb` を使い、seed 123、3,000回のループ、インライン化なしで計測した。2回のウォームアップ後、CRubyとSpinelの前後を交互に各11回実行した。floatの公開APIは `measure_m5_boundary.rb` の30,000呼び出しを使い、新規プロセス4回の各5試行のうち最初の1試行を除いて集計した。これらのCRuby計測はYJITを無効にした。

`global_update` の中央値はSpinelで0.188 → 0.126 ms（33.0%短縮）、CRubyで2.359 → 1.930 ms（18.2%短縮）だった。
CRubyで中央値が増えたケースの最大は `copy_fill` の1.8%。Spinelでは `direct_host` が8.034 → 8.242 ms（2.6%増）、`indirect_host` が13.578 → 13.963 ms（2.8%増）だった。中央値が増えた各ケースで、変更前後のサンプル範囲は重なった。

[計測データ](../benchmark/results/efflorescence-unboxed-globals.json)

## CPUプロファイル

同じRuby 4.0.9のWasmをMIR2キャッシュヒットで実行し、InstrumentsのTime Profilerで前後各1回、1 ms間隔で採取した。表はスタックに `sp_VM_execute` または `sp_VM_execute_flat` があるサンプルのうち、各関数が最上位だった回数。回帰試験と並行して採取し、上の経過時間の計測とは別に実施した。

| 関数 | 変更前（1,168サンプル） | 変更後（566サンプル） |
|---|---:|---:|
| `sp_class_le_mod` / `sp_class_anc_walk` / `sp_class_anc_step` | 64 | 0 |
| `sp_poly_bitop` | 20 | 0 |
| `sp_pd_58a8a817` | 23 | 0 |
| `sp_poly_truthy` | 4 | 1 |
| `sp_VM_execute_flat` | 840 | 468 |
| `sp_FramePool_acquire` | 52 | 8 |
| `sp_VM_calculate` | 25 | 23 |

## 検証

- CRubyとSpinelを含むテストは276件、29,278 assertions、失敗・エラー・省略0件。Steepの型チェックも通過した。
- parityはCRubyとSpinelで各436フィクスチャをWasmtime 49.0.0と照合した。
- `verify_ruby_wasm.rb` は `-e`、`require_relative`、`exit 7` の出力と終了コードが両ランタイムでWasmtimeと一致した。MIR2キャッシュのmissとhitも確認した。
- CRubyとSpinelの境界テストで、start関数、ホストの読み書き、再入、trap、未捕捉Wasm例外、ホスト例外、i64の符号と浮動小数点NaNのペイロードを検証した。Wasmバイナリのglobal importは現行ローダーで未対応のため、インスタンス間の可視性はRubyの `Store` APIで同じ可変 `Global` を共有して検証した。
- Spinelの生成Cで、全8種類のglobal命令が `sp_IntArray` を使い、`sp_poly_` と `sp_box_` を呼ばないことを回帰テストに追加した。[生成Cの検査](efflorescence-generated-c-guards.md)
