# Spinel: 同じ長さの `s[from, n] = v` をその場で書き換える提案

## 概要

Spinel では、mutable な String（`sp_String` handle）への `s[from, n] = v` が、
転送長に関係なく、1 回ごとに文字列全体を約 4 回コピーする。
binary の handle に同じ byte 長の値を書く場合に限り、`memmove` でその場で書き換える
fast path を runtime と codegen に足すことを提案する。
それ以外の場合は、今の splice の経路にそのまま任せる。

- 対象 revision：`matz/spinel` master `93c70470d`。行番号はこの revision のもの。
  測定は `6f1a2c259`（2026-11-04）で行った。該当箇所の実装はこの 2 つの revision で変わっていない。
- きっかけ：Wardite（Wasm runtime）の `memory.copy` / `memory.fill` / `memory.init`。
  Wardite 側は getbyte/setbyte ループに置き換えて回避した（udzura/wardite#24）。
  Spinel 側を直せば、範囲代入を使う Ruby コード全般が速くなる。

## 現状

### 生成 C

local 変数が handle を持つ場合（`data = memory.data; data[dst, n] = bytes`）、
文の位置では次の C が出る（Wardite の `StoreAccess#copy`）。

```c
{ sp_String *_t6 = SP_STR_HDL(lv_data);
  if (sp_String_is_frozen(_t6)) sp_raise_frozen_str(_t6->data);
  const char *lv__sb6 = sp_str_concat(sp_String_cstr(_t6), "");          /* (1) 全体を shadow に複製 */
  SP_GC_ROOT(lv__sb6);
  { sp_int _t7 = dst; sp_int _t8 = n; const char *_v7 = val;
    sp_str_check_mutable(lv__sb6);
    lv__sb6 = sp_str_splice_at(lv__sb6, _t7, _t8, _v7, 0); }             /* (2) head/tail + 2 回の連結 */
  sp_String_set_bin(_t6, lv__sb6);                                        /* (3) 全体を handle に書き戻す */
}
```

- (1) は `emit_sb_shim_swap`（`src/codegen_stmt.c:23899`）が出す。
  呼び出し元は `str_mutate_shared_arms`（`src/codegen_stmt.c:24962`）で、
  local・ivar・reader の receiver を shadow `lv__sb<N>` に読み替える。
  そのうえで文の emitter を走らせ直し、最後に handle へ書き戻す。
  式の位置でも同じ形のものが `src/codegen_call_recv.c` の `sb_iv_expr_shim`（:751）、
  `sb_reader_expr_shim`（:789）、`sb_route_expr_shim`（:822）と、local 用の分岐（:5400 付近）にある。
- (2) の arm は `str_mutate_reassign_arms` の `s[start, len] = v` の分岐（`src/codegen_stmt.c:24405`）。
  shadow は「assignable」として扱われるので、`lv__sb = sp_str_splice_at(lv__sb, ...)` になる。
- `sp_str_splice_at`（`lib/sp_cold.c:1416`）は `sp_str_sub_range` で head と tail を切り出し、
  `sp_str_concat` を 2 回呼んで新しい文字列を作る。
- `sp_String_set_bin`（`lib/sp_string.h:185`）は `len = 0` にしたあと、全体を append し直す。

文字列の byte 長を N とすると、1 回あたり約 4N の memcpy と 4〜5 回の割当（N 規模）が起きる。
binary String の長さは header から O(1) で取れるので、長さの計算はコストにならない。

### 測定（`6f1a2c259`、`-O2`、Apple clang 21、arm64 macOS）

128 byte の前方重複 copy（`data[2112, 128] = data.byteslice(2048, 128).dup`）を
20,000 回行ったときの 1 回あたりの時間（µs）。

| 文字列の長さ | `s[i, n] = v` | `bytesplice` | setbyte ループ | CRuby 4.0.9 の `s[i, n] = v` |
|---|---:|---:|---:|---:|
| 64 KiB | 80.8 | 4.4 | 0.28 | 0.23 |
| 128 KiB | 158.7 | — | 0.28 | 0.16 |
| 1 MiB | 1,275.0 | 48.1 | 0.29 | 0.14 |

時間は文字列の長さに比例する。CRuby はその場で書き換えるので、長さに関係なく一定である。

### 前例：`sp_String_setbyte`

`String#setbyte` には、すでに同じ問題の修正がある（`lib/spinel_rt.h:45`、テスト `test/setbyte_handle_in_place.rb`）。
handle が自分の payload を持つ（marker `0xfd`）ときは `d[j] = v` だけを行い、hash と lcache を無効にする。
alias はどれも同じ handle を見るので、その書き込みが見える。
この提案は、その考え方を範囲代入に広げるものである。

## 提案

### 1. runtime：`sp_String_aset_range`

`lib/sp_string.h` の `sp_String_set_bin_enc` の近くに置く。
下のコードは設計を示すためのもので、まだコンパイルしていない。実装するときにそのまま使えるとは限らない。
`SP_ONE_STRING` は生成コードで常に定義されるが、`sp_String_setbyte` に合わせて、置く場所の条件はそろえる。

```c
/* s[from, n] = val on a handle. A same-length write of binary bytes into a
   binary payload the handle owns is a memmove in place, so every alias sees it
   and nothing the size of the String is copied (as sp_String_setbyte does for
   one byte). Anything else -- a resize, a text receiver or value, an index out
   of range, a payload the handle does not own -- takes the splice, which also
   raises what CRuby raises. */
static inline void sp_String_aset_range(sp_String *s, sp_int from, sp_int n, const char *val) {
  if (SP_UNLIKELY(!s)) sp_nil_recv("[]=");
  if (sp_String_is_frozen(s)) { sp_raise_frozen_str(s->data); return; }
  char *d = s->data;
  sp_int len = s->len, at = from < 0 ? from + len : from;
  if (SP_LIKELY(val && s->binary && sp_str_is_binary(val) &&
                ((const unsigned char *)d)[-1] == 0xfd &&
                n >= 0 && at >= 0 && n <= len - at &&
                (sp_int)sp_str_byte_len(val) == n)) {
    memmove(d + at, val, (size_t)n);   /* val may be a view of this payload */
    sp_fd_publish(s);                  /* hash, 7-bit flag, lcache; len is unchanged */
    return;
  }
  sp_String_set_bin(s, sp_str_splice_at(sp_String_cstr(s), from, n, val, 0));
}
```

fast path に入る条件と、その理由：

| 条件 | 理由 |
|---|---|
| `s->binary && sp_str_is_binary(val)` | CRuby の結果も binary のままで、encoding が変わらない。ASCII だけの binary に UTF-8 を書くと UTF-8 になり、binary でない値を混ぜると `Encoding::CompatibilityError` になることがある。binary 同士なら文字 index と byte index が一致する。 |
| marker `0xfd` | handle が payload を持っている。literal や共有 payload を書き換えない（`sp_String_setbyte` と同じ判定）。 |
| `0 <= at`、`n >= 0`、`n <= len - at` | 例外や切り詰めが起きない範囲に限る。範囲外は fallback に任せ、IndexError と RangeError の文言を今と同じにする。 |
| `byte_len(val) == n` | 長さが変わらないので、`sp_fd_grow` も `len` の更新も要らない。 |

- `memmove` を使うのは、`val` が同じ payload の view でもよいようにするため。
  たとえば `s[a, n] = s[b, n]` で、`s[b, n]` が copy を返さない経路から来る場合がある。
- fast path は割当をしないので、GC root を新たに足す必要はない。
- fallback は、今の `sp_String_set_bin(_t, sp_str_splice_at(...))`（`src/codegen_stmt.c:24400`）と同じ動きにする。

### 2. codegen：handle に対する 3 引数の `[]=` を直接の形にする

`[]=`、`argc == 3`、`argv[0]` が `TY_INT` か boxed（今の分岐の条件と同じ）、
receiver が `TY_STRING` の handle のときは、shadow の shim を使わずに次の形を出す。

```c
{ sp_String *_tH = SP_STR_HDL(<handle の参照>); SP_GC_ROOT(_tH); if (!_tH) sp_nil_recv("[]=");
  sp_int _ts = <start>; sp_int _tl = <len>;      /* 今と同じく、値より先に評価する */
  <emit_str_splice_value(c, recv, argv[2], 0, _ts, b) の前処理>
  sp_String_aset_range(_tH, _ts, _tl, <val>); }
```

直す場所：

1. `src/codegen_stmt.c:24390` の element read 用の分岐（`!assignable && sp_streq(name, "[]=") && argc == 3`）。
   最後の `sp_String_set_bin(_t%d, sp_str_splice_at(sp_String_cstr(_t%d), ...))` を
   `sp_String_aset_range(_t%d, _t%d, _t%d, %s)` に置き換える。これがいちばん小さい変更で、形の見本になる。
2. `str_mutate_shared_arms`（`src/codegen_stmt.c:24962`）の入口。
   上の条件に合うときは、shim（`emit_sb_shim_swap`）を組む前に 1 と同じ直接の形を出して `1` を返す。
   handle の参照には、各分岐が shim に渡しているもの（local の `srefL`、reader の `srefR`、ivar の `srefI`）を使う。
   Wardite の `data[dst, n] = bytes`（local）は、この経路を通っている。
3. 式の位置（`src/codegen_call_recv.c` の :5400 付近の local 分岐と、`sb_*_expr_shim`）。
   `[]=` の値は `val` なので、`({ ...; sp_String_aset_range(...); <val>; })` の形にする。
   文の位置だけを先に直してもよい（Wardite の例では、メソッドの最後の式が値の位置で出ていた）。

まず 1 と 2 だけを入れ、`-c` の出力に `lv__sb<N> = sp_str_concat(sp_String_cstr(` が出なくなることを確かめる。
3 は、生成 C を見て残っている経路があれば足す。

### 3. 任意：長さが変わる場合と `bytesplice`

- 長さが変わる splice も、`sp_fd_grow` と tail の `memmove` で O(len - at) にできる。
  ただし encoding の扱いが増えるので、別の PR にする。
- Spinel の `bytesplice` も O(N) だった（1 MiB で 48µs）。
  同じ helper の byte 版（char boundary の検査は既存のものを使う）で速くなるが、この提案の範囲には含めない。

## テスト

`test/` に、`setbyte_handle_in_place.rb` と同じ形のテストを足す。
名前は `string_aset_range_handle_in_place.rb` などとし、`.expected` は CRuby 4.0 で
`--enable-frozen-string-literal` を付けて作る。
header には `# spinel: share` と `# spinel: gc-stress` を付ける（`CONTRIBUTING.md` の規約による）。

確かめること：

- alias と reader 経由で書き込みが見えること。
  - local の alias（`a = s; s[2, 3] = "xyz".b; p a`）
  - `attr_reader` の receiver（`h.buf[0, 2] = ...`）
  - ivar の receiver
- 結果の bytes と encoding が CRuby と一致すること。
  - binary に binary を書く場合（fast path）
  - ASCII だけの binary に UTF-8 を書く場合（fallback で UTF-8 になる）
  - UTF-8 の receiver に binary の ASCII を書く場合
- 重なる範囲を両方向にコピーしても正しいこと（`s[2, 4] = s.byteslice(0, 4)` と `s[0, 4] = s.byteslice(2, 4)`）。
- 境界の扱いが CRuby と同じこと。
  - 負の start、`at == len` で n が 0、`at > len` の IndexError、負の n の IndexError
  - `n > len - at` のときの切り詰め（fallback の経路）
  - frozen な receiver の FrozenError
- NUL を含む binary の長さが正しいこと（`"\0".b * 16`）。
- 書いたあとに `hash` と `==` が新しい内容を反映すること（`sp_fd_publish` の hash の無効化）。
- 7-bit と分かっている text に、同じ長さの高位 byte を書いたあとも、`length` が正しいこと
  （この場合は fallback を通るが、退行しないことを確かめる）。

性能：

- 上の表のマイクロベンチ（`s[2112, 128] = s.byteslice(2048, 128).dup` を 64 KiB と 1 MiB で回す）で、
  1 回あたりの時間が文字列の長さに依存しなくなること。
- `CONTRIBUTING.md` の review 条件に従い、optcarrot の checksum（59662）と、
  生成 C が変わる場合の callgrind の数値、scale-test の比が 0.05 を超えて上がらないことを確かめる。
- `make gate` を通す。

## 完了の条件

- 次のコードを `-O2` でコンパイルした C で、`sp_str_splice_at` と shadow の `sp_str_concat(sp_String_cstr(...), "")` が呼ばれないこと。

  ```ruby
  data = "\0".b * 65536
  data[2112, 128] = data.byteslice(2048, 128).dup
  ```

- 上のマイクロベンチで、64 KiB と 1 MiB の 1 回あたりの時間がどちらも 1µs 未満であること。
- 新しいテストの `.expected` が CRuby と一致し、`make gate` が通ること。
- Wardite の udzura/wardite#24 を元の範囲代入に戻しても、`benchmark/measure_m2.rb` の
  Spinel の copy_fill が 2ms 未満になること（置き換え前は 168ms、setbyte 版は 1.08ms）。
  これは任意の確認で、Wardite 側をどうするかは別に判断する。
