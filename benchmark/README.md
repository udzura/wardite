# Wardite i32 benchmark

## Phase 2 optimization comparison

The Phase 2 sample below predates the integer-literal dispatch follow-up; see
[the isolated dispatch comparison](#integer-literal-dispatch) for that change.

```sh
ruby benchmark/compare_optimizations.rb 100000 123
# Also measure each feature independently disabled:
ABLATIONS=1 RUNS=3 WARMUPS=1 ruby benchmark/compare_optimizations.rb 100000 123
```

Requires Ruby, Spinel/C toolchain, make and wasm-tools. The script builds the CLI
and phase worker, verifies every measured CLI/worker pair against the independent
reference, collects detailed counters in separate untimed runs, and measures
CRuby, available YJIT and Spinel. Defaults: five samples after two warmups.
`unoptimized` disables all Phase 2 features in the current code, while
`optimized` enables all of them. Each-feature-off measurements keep the other
features enabled; their effects interact (e.g. disabling immediates also prevents
immediate shift/XOR fusion), so speedups are not additive.

The report `build/benchmark/optimizations.json` contains raw samples, phase and
whole-process means, CRuby execution allocations and per-opcode counters.
Time measurement does not enable MIR counters. Both phase and CLI measurements
include the same Ruby-facing boxed return boundary. Spinel allocations are `n/a`.
The shared phase loader creates the default runtime, then the selected MIR VM is
constructed in the MIR phase; the fixture has no start function. Phase timing
uses a separate executable, whose Spinel inference can differ from the CLI.
`SPINEL` and `SPINELFLAGS` choose the compiler/flags (default `-O2`).

For an independently built Phase 1 baseline (requires commit `67fbfae` locally):

```sh
mkdir -p build/phase1 build/benchmark
git archive 67fbfae | tar -x -C build/phase1
make -C build/phase1 spinel
spinel -I build/phase1/lib --strict-require -O2 build/phase1/benchmark/engine_phases.rb -o build/benchmark/phase1-engine-phases
PHASE1_ROOT=build/phase1 PHASE1_BIN=build/phase1/build/wardite PHASE1_WORKER=build/benchmark/phase1-engine-phases ruby benchmark/compare_optimizations.rb 100000 123
```

The native baseline defaults to `build/benchmark/phase1-wardite` when
`PHASE1_BIN` is omitted. The archived CRuby source runs independently, rather
than using the current engine's disabled-pass mode as a substitute for Phase 1.
[Implementation and metric definitions](../docs/efflorescence-phase2.md)
([日本語](../docs/efflorescence-phase2-ja.md)).

### Phase 2 sample (2026-11-04)

macOS arm64, CRuby 4.0.9 (`3e93b23afc`), Spinel `2026.10.25+1967`
(`6e7fc1355`, Apple clang 21.0.0), `-O2` and default integer overflow checks.
100,000 rounds, seed 123, five samples after two warmups. The Phase 1 baseline
is the archived source and independent native executables from `67fbfae`.
All 18 CLI/worker pairs matched checksum `3870791521` before timing, and every
timed sample was checked again. Timings are milliseconds, not speedup factors.

Whole CLI process time:

| Runtime | Phase 1 inline | Phase 2 inline | Phase 1 call | Phase 2 call |
| --- | ---: | ---: | ---: | ---: |
| CRuby | 414.82 | 317.33 | 668.59 | 575.44 |
| CRuby + YJIT | 215.49 | 159.61 | 336.77 | 235.56 |
| Spinel | 62.58 | 17.83 | 86.63 | 30.71 |

Execution phase only (separate worker binaries):

| Runtime | Phase 1 inline | Phase 2 inline | Phase 1 call | Phase 2 call |
| --- | ---: | ---: | ---: | ---: |
| CRuby | 393.16 | 253.94 | 609.77 | 500.60 |
| CRuby + YJIT | 153.46 | 65.38 | 231.06 | 141.26 |
| Spinel | 30.98 | 12.25 | 49.03 | 23.33 |

Current-code unoptimized execution was also measured: Spinel 33.07/56.26 ms,
CRuby 375.25/667.11 ms, YJIT 126.85/241.11 ms (inline/call). This is distinct
from the independently compiled Phase 1 baseline. Phase 2 MIR construction
averaged 0.58/0.61 ms on CRuby, 23.25/23.30 ms with YJIT, and 0.17/0.18 ms
on Spinel. This cost matters for short workloads.

CRuby's `call_mix` execution allocations fell from 200,074 in current-code
unoptimized mode to 79 with all features enabled. These counts include API
setup and one boxed return, and exclude module loading/translation. They do
not imply the same total allocation count on Spinel; instrumented MIR separately
confirmed Frame allocations falling from 100,001 to 2 on both runtimes.

An exploratory each-feature-off run (three CLI samples after one warmup) gave
the following Spinel process times. These use the same CLI boundary as above;
they are diagnostic observations, not independent additive speedups:

| Disabled feature | inline | call |
| --- | ---: | ---: |
| None | 16.43 | 30.18 |
| COPY reduction | 19.95 | 34.55 |
| Immediates | 17.52 | 31.82 |
| Branch fusion | 16.51 | 31.75 |
| Superinstructions | 17.81 | 32.10 |
| Flat code | 40.05 | 60.38 |
| Frame reuse | 15.75 | 33.61 |

Flat code had the clearest Spinel benefit. Frame reuse primarily helped call
workloads. Some CRuby/YJIT variants were within noise or faster with an
individual feature disabled; feature defaults prioritize Spinel while retaining
the individual controls. Accumulators and basic-block dispatch are deferred.
Raw local reports are `build/benchmark/optimizations.json` (five-sample run)
and `build/benchmark/optimizations-experiment.json` (exploratory run).

### Integer-literal dispatch

```sh
ruby benchmark/compare_dispatch.rb 100000 123
RUNTIMES=Spinel ruby benchmark/compare_dispatch.rb 1000000 123
```

The script compares `when Opcode::NAME` with `when <integer literal>` while
keeping all Phase 2 features enabled in both variants. It creates a temporary
constant-label baseline from the current source's annotated dispatch labels,
builds both CLI and worker with the same Spinel/flags, and verifies every
CLI/worker pair against the independent reference. Paired samples alternate
order; all timed invocations are checked again. Defaults are five samples after
two warmups. `RUNTIMES` can select `Spinel`, `CRuby`, and/or available `YJIT`,
comma-separated. Raw samples are saved to `build/benchmark/dispatch.json`.

On 2026-11-04, with the same CRuby/Spinel toolchain and `-O2` as above,
100,000 rounds and seed 123, five measured processes after two warmups gave
these execution-phase means (milliseconds):

| Runtime | Constant inline | Literal inline | Constant call | Literal call |
| --- | ---: | ---: | ---: | ---: |
| CRuby | 254.08 | 119.21 | 492.31 | 303.84 |
| CRuby + YJIT | 65.93 | 58.71 | 140.36 | 129.40 |
| Spinel | 10.11 | 9.13 | 25.93 | 21.21 |

The short Spinel constant-label call samples had a 6.53 ms standard deviation,
so a longer Spinel-only run used **1,000,000 rounds**, seed 123. All calls
returned `1259766978`. Five samples after two warmups gave:

| Spinel export | Constant execution | Literal execution | Time reduction |
| --- | ---: | ---: | ---: |
| `inline_mix` | 100.43 ± 0.49 ms | 90.68 ± 0.28 ms | 9.7% |
| `call_mix` | 229.76 ± 0.30 ms | 209.93 ± 0.94 ms | 8.6% |

Uncertainty is the sample standard deviation, not a confidence interval.
Whole CLI process times in that longer run were 104.94 → 97.33 ms for inline
and 248.37 → 221.64 ms for call. Thus this change gives a further measured
Spinel improvement beyond the other Phase 2 optimizations; the short call run's
larger apparent gain should not be treated as the stable speedup.
Local raw reports are `build/benchmark/dispatch-100k.json` and
`build/benchmark/dispatch-million.json` (also the latest `dispatch.json`).

## Compare the stack and Efflorescence engines

```sh
ruby benchmark/compare_engines.rb 100000 123
# Optional sample counts (default: 5 samples after 2 warmups):
RUNS=3 WARMUPS=1 ruby benchmark/compare_engines.rb 100000 123
```

Requires Ruby, Spinel/C toolchain, make and wasm-tools. YJIT is included when
available. The script builds both native entry points, checks **all eight Phase
1 input cases** on both exports and both engines on every runtime against an
independent reference, then measures the requested input. A mismatch aborts.

Results include whole CLI process time and separate load, MIR translation and
execution times from `engine_phases.rb`, compiled unchanged by Spinel. Phase
timings come from a separate process per sample, with one call per process;
they include frame setup and the final Ruby-facing result box. The loader phase
creates the shared instance with the default runtime; the fixture has no start
function, so it executes no guest instructions. For Efflorescence, the next
phase constructs the selected VM from that instance (including a second, empty
Runtime setup for stack samples). End-to-end samples use the real
CLI with `--new-engine` and therefore include normal engine selection, startup,
load, translation, execution and output. Warmups are separate processes, so YJIT
compiles anew for each sample. Native compilation is outside measurement.
Phase values are diagnostic and do not sum to the CLI time: they use a separate
entry point, which can also change Spinel's whole-program type inference.

Raw samples and means are saved to `build/benchmark/engines.json`. `SPINEL` and
`SPINELFLAGS` can select the compiler and flags (default `-O2`, with the default
overflow checks enabled). [Engine design and scope](../docs/efflorescence.md).

### Phase 1 sample (2026-11-03)

macOS arm64, CRuby 4.0.9 (`3e93b23afc`), Spinel `2026.10.25+1967`
(`6e7fc1355`, Apple clang 21.0.0), `-O2`, default overflow checks, 100,000
rounds, seed 123. Five measured processes per command after two warmups.
All eight acceptance input cases passed on all six engine/runtime combinations
before measurement. Every measured invocation returned unsigned checksum
`3870791521`, printed by the CLI as `I32(-424175775)`.

Mean whole CLI process time, in milliseconds:

| Runtime | Stack inline | Efflorescence inline | Stack call | Efflorescence call |
| --- | ---: | ---: | ---: | ---: |
| CRuby | 1032.56 | 409.63 | 1218.78 | 656.89 |
| CRuby + YJIT | 488.49 | 198.24 | 627.45 | 285.86 |
| Spinel | 341.05 | 59.10 | 405.80 | 83.69 |

Mean execution phase only, in milliseconds, from the separate phase runner:

| Runtime | Stack inline | Efflorescence inline | Stack call | Efflorescence call |
| --- | ---: | ---: | ---: | ---: |
| CRuby | 968.36 | 348.32 | 1157.74 | 598.88 |
| CRuby + YJIT | 423.70 | 119.66 | 550.27 | 208.93 |
| Spinel | 318.36 | 30.08 | 370.79 | 48.55 |

Efflorescence MIR construction averaged 0.12 ms on CRuby, 14.54 ms with YJIT
(including JIT work in that phase), and 0.03 ms on Spinel. Loading averaged
0.11–0.38 ms without YJIT, and 3.3–3.4 ms with it. These are observations for
this machine and input; rerun before comparing with older samples below.

The original `compare.rb` below remains available for comparisons with external
Wasm runtimes.

`i32_mix.wat` provides two exports with the same `(rounds: i32, seed: i32) -> i32`
signature and checksum:

- `inline_mix`: dependent integer operations directly inside a loop. Exercises
  opcode dispatch, local variables, arithmetic, shifts, XOR, and branches.
- `call_mix`: the same calculation through an internal Wasm function on each
  iteration. Adds argument passing and call-frame creation/return.

The calculation mixes a changing 32-bit value using XOR, shifts, multiplication,
and addition. Every iteration contributes to the returned checksum. Work size
and seed are runtime arguments. There are no imports, WASI calls, or I/O inside
Wasm, and no growing memory allocation by the guest program. Wardite itself
still allocates value objects and, for `call_mix`, frames during interpretation.

## Run

Requirements: Ruby with YJIT, Spinel and its C toolchain, `make`, `wasm-tools`,
`wasmtime`, and `hyperfine` on PATH. No Bundler dependencies are needed for the comparison script.
Run from the repository root:

```sh
ruby benchmark/compare.rb
# Adjust work size and seed:
ruby benchmark/compare.rb 200000 42
```

The script compiles the WAT and the Spinel CLI, computes an independent Ruby
reference, and checks all eight command results before timing. It compares CRuby
with YJIT explicitly disabled, CRuby with YJIT enabled, Spinel, and Wasmtime, for each export. A mismatch or unavailable YJIT stops the run. Defaults: 100,000 rounds,
seed 123456789, two warmup processes, and five measured processes per command.
The expected checksum with these defaults is `I32(261279018)`.

Results are written to `build/benchmark/results.json` (overwritten each run).
The Spinel compiler build and reference/result checks are outside the timed commands.
Hyperfine runs commands without a shell. Wasmtime runs with `-C cache=n`, so
each process compiles the module rather than reusing a compiled-module cache.

For a single invocation after building:

```sh
ruby -Ilib exe/wardite --no-wasi --invoke inline_mix -- build/benchmark/i32_mix.wasm 100000 123456789
ruby --yjit -Ilib exe/wardite --no-wasi --invoke inline_mix -- build/benchmark/i32_mix.wasm 100000 123456789
./build/wardite --no-wasi --invoke inline_mix -- build/benchmark/i32_mix.wasm 100000 123456789
wasmtime run -C cache=n --invoke inline_mix build/benchmark/i32_mix.wasm 100000 123456789
```

## Interpret results

These are **whole CLI process wall times**: Ruby/native startup, module loading,
execution, and printing the checksum. Wasmtime also compiles the Wasm module
in each timed process; its compiled-module cache is explicitly disabled. They measure the cost of running this
program through each runtime's CLI, rather than execution-loop throughput alone.
Hyperfine warmups start separate processes; YJIT compiles anew in each process.
Increase rounds to reduce the share spent on startup/loading, and keep the same
rounds and seed across comparisons. Zero rounds return the seed without mixing
and can be used to inspect startup/loading overhead.

Compare runtimes **within the same export**. Compare the two exports within a
runtime to examine the additional cost of Wasm calls. An optimizing compiler
such as Wasmtime may inline the helper, so its two exports need not retain the
same call overhead that an interpreter does. This workload covers i32
execution and calls; it does not measure memory instructions, floating point,
WASI, or arbitrary real-world programs.

Zero/one rounds and high-bit seeds were additionally checked against CRuby,
Spinel, and Wasmtime during development.

### Sample run (2026-11-03)

macOS arm64, CRuby 4.0.8, Spinel `2026.10.25+1967` (`6e7fc1355`, Apple clang
21.0.0), `-O2 --int-overflow=promote`, Wasmtime 49.0.0 (`-C cache=n`),
100,000 rounds, seed 123456789. Mean wall
time ± standard deviation over five runs (two warmup processes):

| Export | CRuby | CRuby + YJIT | Spinel | Wasmtime |
| --- | ---: | ---: | ---: | ---: |
| `inline_mix` | 682.2 ± 7.1 ms | 275.0 ± 11.2 ms | 167.1 ± 2.2 ms | 4.7 ± 0.2 ms |
| `call_mix` | 811.1 ± 6.7 ms | 357.5 ± 3.2 ms | 204.7 ± 1.4 ms | 5.3 ± 0.3 ms |

All eight commands returned `I32(261279018)`. These numbers describe this machine and
CLI workload, and should be remeasured when the runtime or compiler changes.
