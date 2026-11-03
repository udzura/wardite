# Wardite i32 benchmark

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
