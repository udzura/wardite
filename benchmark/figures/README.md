# New VM / Spinel comparison

![Candlestick-style comparison](spinel_new_vm_candlestick.png)

These eight summary rows use the user's final results, with five runs per row.
Efflorescence / Spinel averaged **6.6 ms** for both exports; Wasmtime averaged
6.8 ms for `inline_mix` and 6.9 ms for `call_mix`. Their ranges overlap, so the
figure does not establish a statistically significant lead.

Efflorescence uses while-based flat dispatch and Spinel's local fetch-root-elision
patch (`6f1a2c259`). The compiler patch is recorded separately from the Wardite
implementation; see the [investigation](../../docs/efflorescence-generated-c-guards.md).

The body shows mean ± standard deviation, the central line shows the mean,
and whiskers show the observed minimum and maximum. Both panels use the same
millisecond scale. Mean ± standard deviation can extend beyond the observed
range; it is preserved without clipping. No quartiles or per-run values are
inferred from the summaries.

These are **whole CLI process times**, including startup, module loading and
execution. Wasmtime also compiles the module in each process, with its
compiled-module cache disabled. They are not execution-loop-only timings.

The supplied, one-decimal-millisecond summaries are in
`spinel_new_vm_summary.json` and `.csv`. They preserve the five-run summary
supplied in the conversation; the mutable `build/benchmark/results.json` is not
used when regenerating this figure. No per-run observations are inferred.
PNG and SVG exports are included. To regenerate on macOS with Matplotlib and the
Hiragino Kaku Gothic W3 system font installed:

```sh
python3 plot_spinel_comparison.py
```

Run from this directory, or pass the script's path from the repository root.
