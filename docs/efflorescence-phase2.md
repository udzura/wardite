# Efflorescence VM — Phase 2

[日本語](efflorescence-phase2-ja.md) · [Phase 1](efflorescence.md)

Phase 2 reduces MIR execution overhead. The stack VM remains Wardite's default;
`--new-engine` selects Efflorescence with the optimizations below enabled.
The supported Wasm subset is unchanged. Unsupported instructions still fail
explicitly, including in unreachable or unexported functions.

## Pipeline and controls

```text
Wasm → Translator → semantic MIR (retained)
                  → CopyPropagation
                  → ImmediateSpecialization
                  → BranchFusion
                  → Superinstructions
                  → optimized MIR (retained)
                  → optional profiling instrumentation
                  → Lowerer → executable integer array → VM
```

Each pass operates on a function. `Optimizer` copies the semantic MIR before
changing it. `Rewrite` maps old instruction ordinals to new ones and repairs all
branch targets after each rewrite. `Analysis` identifies basic-block entries
and counts register definitions and uses across the whole function.

```sh
# Default optimized execution
ruby -Ilib exe/wardite --new-engine --no-wasi --invoke call_mix build/benchmark/i32_mix.wasm 100000 123

# Disable one feature, or several by repeating the option
ruby -Ilib exe/wardite --new-engine --mir-disable copy --mir-disable flat --no-wasi --invoke call_mix build/benchmark/i32_mix.wasm 100000 123

# Semantic MIR execution with all six features disabled
ruby -Ilib exe/wardite --new-engine --mir-disable all --no-wasi --invoke call_mix build/benchmark/i32_mix.wasm 100000 123

# Inspect before/after MIR, or collect counters separately from timing
ruby -Ilib exe/wardite --new-engine --mir-dump --mir-profile --no-wasi --invoke call_mix build/benchmark/i32_mix.wasm 10 123
```

`copy`, `immediate`, `branch`, `superinstruction`, `flat` and `frames` can be
disabled independently. Unknown names raise an error. MIR CLI options require
`--new-engine`. The normal checksum output is unchanged unless inspection or
profiling is explicitly requested.

```ruby
instance = Wardite.new(path: "build/benchmark/i32_mix.wasm",
  enable_wasi: false, engine: :efflorescence,
  disabled_optimizations: [:superinstruction], mir_profile: true)
vm = instance.runtime
vm.call("call_mix", [1000, 123])
puts vm.dump_mir
puts vm.metrics.report
```

The same keywords are accepted by `BinaryLoader.load_from_buffer`.
Direct `VM.new` accepts `disabled_optimizations:` and `profile:`.

## Optimizations and safety

| Feature | Implementation | Correctness boundary |
| --- | --- | --- |
| COPY reduction | Redirect an adjacent producer into its COPY destination; propagate copies locally; remove self-copies and globally unread copies | Producer temporaries must have one definition and one use. No incoming edge may target an absorbed COPY. Aliases reset at basic-block boundaries and are invalidated whenever their source is overwritten. |
| Immediates | Embed immutable constant-register values in ADD/SUB/MUL/XOR/SHL/SHR_U operands | Only ADD/MUL/XOR may swap a constant left operand. Shift counts remain masked; multiplication still uses bounded 16-bit limbs. |
| Branch fusion | `I32_EQZ tmp, src; BR_IF tmp, pc` → `BR_IF_ZERO src, pc` | The temporary is not a local, has one definition/use, and the second instruction has no incoming edge. |
| Superinstructions | Fuse immediate logical-right/left shift followed by XOR with the original source | The intermediate has one definition/use and the XOR is not a basic-block entry. No benchmark-specific whole-function instruction or function inlining is used. |
| Flat execution | Lower to four integers per instruction: opcode and three operands | Branch ordinals become offsets multiplied by four. CALL uses an out-of-line `CallSite` with the resolved callee and argument-register array, allowing any supported arity. |
| Frame reuse | Per-function free lists owned by one public invocation | Active frames are never pooled. Reused frames restore every register, including locals/constants/temporaries, and reset PC/return destination. Recursion and overlapping invocations have independent active frames. |

The object-based semantic executor remains available with `--mir-disable flat`,
including when individual MIR passes remain enabled. This permits differential
execution of representation changes. `--mir-disable all` is a semantic baseline
in the current code, not the exact Phase 1 binary: setup code and Spinel's
whole-program inference can differ. The benchmark can also run commit `67fbfae`
as an independently built baseline.

## Inspection and metrics

`VM#semantic_ir` is the original translation. `optimized_ir` is the result of
the passes; `ir` is the executed IR, which additionally contains PROFILE
instructions when profiling is requested. Flat code is in `Function#bytecode`.
Normal execution does not test a profiling flag or update counters per MIR op.

Profiling inserts a PROFILE record before each MIR instruction and retargets
branches to those records. Counters exclude the instrumentation's own dispatches.
Register access counts model MIR operand reads/writes, including internal-call
argument copies and return destinations; they exclude frame initialization,
Ruby boundary setup and instruction fetches. They are not hardware memory-access
counters. `metrics` reports the most recent public invocation. Counter-enabled
execution is deliberately excluded from all timing measurements.

At 100,000 rounds and seed 123, both exports return unsigned `3870791521`:

| Metric | Inline unoptimized | Inline optimized | Call unoptimized | Call optimized |
| --- | ---: | ---: | ---: | ---: |
| Dispatches | 1,300,005 | 700,003 | 1,600,005 | 900,003 |
| COPY executions | 300,002 | 1 | 400,002 | 1 |
| Register reads | 1,900,005 | 600,003 | 2,200,005 | 800,003 |
| Register writes | 1,100,003 | 500,001 | 1,400,003 | 700,001 |
| Frame allocations | 1 | 1 | 100,001 | 2 |

Across the three functions, static MIR falls from 35 to 20 instructions and
from 11 to 2 COPYs. Register count remains 37: unused temporary and constant
slots are not compacted in this phase.

Spinel's generated C was inspected with:

```sh
spinel -I lib --strict-require -O2 -c exe/wardite -o build/benchmark/phase2-wardite.c
```

Both the flat code and frame registers are `sp_IntArray*`; operand fetches use
`sp_IntArray_get`, and dispatch performs no `Instruction#[]` calls. Object
metadata and frame/call-site collections may still use generic arrays.

### Integer-literal dispatch

Both execution loops deliberately use `when 0 # Opcode::COPY` rather than
`when Opcode::COPY`. In the tested Spinel version, the
[integer-case fast path in `emit_case`](https://github.com/matz/spinel/blob/master/src/codegen_stmt.c#L11032-L11101)
requires integer literal AST nodes. Constant references do not meet that
condition, even when their values are integers. The literal form produces a C
`switch` covering opcodes 0–22 instead of the constant-comparison chain.

Opcode constants remain the source of truth for MIR construction and optimizer
passes. Each dispatch label retains its Opcode name in a comment; a regression
test checks every literal against that constant and checks complete coverage.
The native suite additionally compiles the CLI to C and verifies the switches
in both the flat and semantic executors. With this follow-up included, the full
suite passed **88 tests and 4,466 assertions**, with no failures/errors/omissions;
type checks also passed.

```sh
ruby benchmark/compare_dispatch.rb 100000 123
# Focus on Spinel, optionally increasing the workload:
RUNTIMES=Spinel ruby benchmark/compare_dispatch.rb 1000000 123
```

The comparison reconstructs constant-label dispatch in a temporary copy of the
current source, builds it independently, and keeps all other optimizations and
the public call boundary identical. Paired constant/literal samples alternate
order. Checksums are verified before timing and for every measured call.
Results are saved to `build/benchmark/dispatch.json`; the temporary baseline is
removed after the run. See the [recorded dispatch comparison](../benchmark/README.md#integer-literal-dispatch).
In the longer Spinel run (1,000,000 rounds, seed 123), execution time fell from
100.43 to 90.68 ms for inline and from 229.76 to 209.93 ms for call: 9.7% and
8.6% reductions, respectively, over five samples after two warmups.

## Validation and benchmarking

```sh
bundle exec rake check
make spinel
WARDITE_SPINEL_BIN="$PWD/build/wardite" bundle exec rake test
ruby benchmark/compare_optimizations.rb 100000 123
ABLATIONS=1 RUNS=3 WARMUPS=1 ruby benchmark/compare_optimizations.rb 100000 123
```

The full unchanged acceptance WAT and all eight original inputs run with the
default optimizer, every feature independently disabled and all features
disabled, on CRuby and Spinel. Additional tests exercise snapshots across
overwrites/edges/calls/loops, incoming edges into candidate peepholes, live
intermediates, unsigned products, shift masks, operand order, frame-local
reinitialization, recursion, overlapping public calls and exact counter values.
The existing stack VM tests remain part of the suite.

On 2026-11-04 the full suite passed on CRuby 4.0.9 with the Spinel native tests
enabled: **88 tests, 4,466 assertions, no failures/errors/omissions**.
`bundle exec rake check` also passed. Spinel was `2026.10.25+1967`
(`6e7fc1355`), built with `-O2` and default overflow checks.
[Recorded Phase 1/2 timings and feature-off measurements](../benchmark/README.md#phase-2-sample-2026-11-04).
Defaults prioritize the measured Spinel benefit; an individual feature need not
help CRuby/YJIT to the same extent.

The comparison script verifies every measured CLI and worker against an
independent modulo-based reference before timing. It measures CLI process time,
load/translation/execution phases, and CRuby's execution allocation count.
Workers use the same Ruby-facing `call` boundary as the CLI. Spinel allocation
counts are reported as unavailable, rather than estimated from CRuby.
Raw samples, means, per-opcode counters and static MIR summaries are saved to
`build/benchmark/optimizations.json`. `ABLATIONS=1` adds each-feature-off variants.

Phase timing uses a separately compiled worker, so phase values need not sum to
CLI time and Spinel type inference can differ between those entry points.
Warmups start separate processes; YJIT compilation occurs anew in every sample.
Default sample counts are five measured processes after two warmups.

For an independent Phase 1 comparison, first preserve/build sources from
`67fbfae` in a separate directory, then set `PHASE1_ROOT`, `PHASE1_BIN` and
`PHASE1_WORKER`; see [benchmark instructions](../benchmark/README.md).

## Remaining experiments

Accumulator execution, basic-block dispatch, constant folding, register
compaction, shared register stacks and Ruby/native code generation are not
implemented. The existing pass boundary is the place to experiment with them.
Wasm opcode coverage remains a separate task; a future opcode must first define
its operand reads/writes/control effects before an optimizer can handle it.

The design references were [WasmKit's register interpreter](https://github.com/swiftwasm/WasmKit/blob/main/Documentation/RegisterMachine.md)
and [Wasmi 2.0's optimization discussion](https://wasmi-labs.github.io/blog/posts/wasmi-v2.0/).
Their native dispatch/accumulator techniques are not assumed to have the same
costs in Ruby; the implemented variants are evaluated on CRuby and Spinel.
