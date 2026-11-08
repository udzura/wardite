# Efflorescence VM (Phase 1)

[日本語](efflorescence-ja.md)

Current coverage includes [M1 i32, structured control and new EH](efflorescence-m1.md),
[M2 memory and globals](efflorescence-m2.md), [M3 host and indirect calls](efflorescence-m3.md),
and [M4 i64](efflorescence-m4.md).
The Phase 1 limitations below are historical.

This document records Phase 1 (`67fbfae`). Current Efflorescence enables the
[Phase 2 optimizations](efflorescence-phase2.md) by default; `--mir-disable all`
selects unoptimized MIR lowered to the same flat bytecode executor. Wardite's default is still the stack VM.

Efflorescence is Wardite's opt-in, pure Ruby register interpreter. The default
remains `Wardite::Runtime`, the stack interpreter. Both engines share the binary
loader, decoded Wasm instructions, store and exports; execution is independent.

```sh
wasm-tools parse benchmark/i32_mix.wat -o build/i32_mix.wasm
ruby -Ilib exe/wardite --new-engine --no-wasi --invoke inline_mix build/i32_mix.wasm 100000 123
ruby -Ilib exe/wardite --new-engine --no-wasi --invoke call_mix build/i32_mix.wasm 100000 123
# Both: return value: I32(-424175775)
```

The equivalent Ruby API is:

```ruby
require "wardite"
instance = Wardite.new(path: "build/i32_mix.wasm", enable_wasi: false, engine: :efflorescence)
instance.runtime.call("call_mix", [100000, 123]) # Wardite::I32, same as Runtime
instance.runtime.call_unboxed("call_mix", [100000, 123]) # 3870791521 (Integer)
```

Spinel uses the same sources (`make spinel`). Invoke exported functions through
`runtime.call` or the CLI: Spinel currently does not dispatch undefined methods
through Ruby's `method_missing` (including the existing VM's convenience API).
No Spinel-specific runtime API or global integer-overflow option is needed.

## MIR and execution

All new implementation classes live under `Wardite::Efflorescence`:

| Class | Responsibility |
| --- | --- |
| `IR` | Module's translated functions, indexed by Wasm function index |
| `Function` | Index, parameter/result types, local count, register count, initial register values, instructions |
| `Instruction` / `Opcode` | Integer operands and integer opcode constants |
| `Translator` / `Translator::Control` | Abstract operand stack, structured labels, snapshots, result joins and PC fixups |
| `Frame` | Function, Integer register array, return destination and saved PC |
| `VM` | Export checks, Ruby boundary conversion, independent dispatch and explicit call frames |

`Instruction` wraps an `Array<Integer>`. The wrapper gives Spinel a typed operand
accessor even when it represents the outer instruction table as a generic array.
Instructions are allocated during translation, never during dispatch.

| MIR form | Meaning |
| --- | --- |
| `[COPY, dst, src]` | Copy register |
| `[I32_ADD/SUB/MUL/XOR/SHL/SHR_U, dst, lhs, rhs]` | Wasm binary operation |
| `[I32_EQZ, dst, src]` | Zero test |
| `[BR, pc]`, `[BR_IF, condition, pc]` | Absolute MIR target |
| `[CALL, dst, function_index, *argument_registers]` | Internal call (`dst = -1` for void) |
| `[RETURN, src]` | Return (`src = -1` for void) |
| `[TRAP]` | Wasm `unreachable` |

Locals occupy the first registers. `local.get` pushes a source in the translator,
without emitting a runtime instruction. Before overwriting a local that remains
on the abstract stack, the translator copies its old value to a temporary and
rewrites those sources. At block/loop entry, live local sources are snapshotted
before the branch target, preserving stack prefixes across edges and backedges.
`local.tee` uses the same mechanism. Constants are deduplicated into immutable
initial register slots; `i32.const` emits no runtime instruction.

Each arithmetic result has a temporary slot. Result-bearing blocks/functions
have join slots; incoming branches and normal completion copy into those slots.
Loop branches target the header and carry no arguments; block branches target
the end and carry their result. Unconditional transfers make the rest of that
control region unreachable. There are no runtime Wasm labels or operand stack.

Registers always contain unsigned `0..0xffffffff` Ruby Integers. Add/subtract
wrap, shift counts use their low five bits, and multiply uses 16-bit limbs to
avoid overflowing Spinel's signed native word before masking the result. Internal
calls copy Integers between independent frames. Only `VM#call` boxes the final
Ruby-facing result; `call_unboxed` does not. Calls use an explicit frame array,
so guest recursion does not consume Ruby's method call stack.

No optimization pass is required to execute this MIR. Future passes can operate
on each Function between translation and execution. Conservative COPYs and
temporary registers are intentionally retained for Phase 1.

## Scope and validation

Supported: i32 parameters/results/locals/constants, get/set/tee, add/sub/mul/xor,
shl/shr_u/eqz, block/loop/br/br_if/end, call/return, nop/drop/unreachable and
function exports. Blocks and loops can have zero or one i32 result; loop
parameters and type-index block signatures are unsupported.

Imports/host functions, WASI calls, memory/global/table instructions, if/else,
other numeric operations, multi-value signatures and advanced Wasm proposals
raise `UnsupportedFeature`. Every defined function is translated eagerly, so an
unsupported instruction is rejected even in dead code or an unexported function.
There is no fallback to `Wardite::Runtime`. The shared loader's existing binary
decoding and validation limitations still apply.

```sh
bundle exec rake test
bundle exec rake check
make spinel-test RUBY="bundle exec ruby"
ruby benchmark/compare_engines.rb 100000 123
```

Tests compile the **entire unchanged** `benchmark/i32_mix.wat` using the existing
`wasm-tools parse` flow. No prebuilt fixture or reduced workload is substituted.
All eight specified input pairs run against both exports, both engines and an
independent modulo-based reference on CRuby and Spinel. Additional tests cover
snapshots, result branches, loop prefixes, recursion, void calls, normalization,
shift counts, unsigned products, unsupported features and CLI selection. A
TracePoint regression checks that 1,000 internal calls allocate just one I32 at
the Ruby return boundary and never execute a `Wardite::Runtime` method.

Verified on 2026-11-03 with CRuby 4.0.9 and Spinel `2026.10.25+1967`
(`6e7fc1355`, default integer overflow checks): **75 tests, 1,106 assertions,
zero failures/errors/omissions**, with `WARDITE_SPINEL_BIN` enabled for the full
suite. `bundle exec rake check` also passed. Both exports on both engines and
both runtimes produced these unsigned results:

| Rounds | Seed | Checksum |
| ---: | ---: | ---: |
| 0 | 0 | 0 |
| 0 | 123 | 123 |
| 1 | 0 | 186080479 |
| 1 | 123 | 434058398 |
| 10 | 123 | 483678737 |
| 1000 | 123 | 1949289519 |
| 1000 | 4294967295 | 1895198137 |
| 100000 | 123 | 3870791521 |

[Recorded performance comparison](../benchmark/README.md#phase-1-sample-2026-11-03).

Next steps: reduce COPYs and temporary count in independent passes, specialize
immediates, improve instruction-table representation for Spinel, reuse frames,
and extend supported Wasm operations/control constructs. Performance is not a
Phase 1 acceptance criterion.
