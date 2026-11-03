# Wardite i32 benchmark

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
