# Efflorescence M5 の浮動小数点対応

[ADR 0005](adr/0005-efflorescence-m5-floating-point.md) の実装記録。

## 丸め方式

binary32 の演算には binary64 の中間値を使い、各命令の出口で binary32 に丸める。加減算では指数差が25以下なら中間の有効桁は50 bit以内に収まる。指数差がそれより大きければ、小さい項は大きい項から最も近い binary32 の丸め境界まで届かない。積の有効桁は48 bit以内に収まる。

除算の正規化した商は高々24 bitの分母を持つ有理数に2の累乗を掛けた形になる。商を [1, 2) にスケールすると、binary32 の中点と一致しない場合の距離は 2⁻⁴⁸ より大きい。平方根では同じスケールの中点を二乗し、radicand との差を取る。差がゼロでなければ絶対値は 2⁻⁴⁸ 以上で、根と中点との距離は 2⁻⁵⁰ より大きい。このため binary64 で丸めても binary32 の中点を越えたり、新たな tie が生じたりしない。subnormal の中点の間隔はさらに広く、ゼロとの境界は2の累乗なので同じ判定を適用できる。整数から float への変換にはこの議論を適用せず、整数の有効桁から丸める。

binary64 の四則と平方根はホストの binary64 演算を使う。平方根は符号付きゼロを先に返す。CRuby の `Math.sqrt(-0.0)` が正のゼロを返すためである。CRuby 4.0.9 と Spinel の `-O2` で、固定の bit fixture により両精度の bit 往復、binary32 の subnormal 付近の除算の tie とその上下、平方根の中点付近、binary64 の除算・平方根・subnormal、±0、NaN、infinity を確認する。

演算結果の丸め、特殊値、NaN の根拠は WebAssembly 3.0 の [Numerics](https://webassembly.github.io/spec/core/exec/numerics.html)。
