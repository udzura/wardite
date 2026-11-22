# Wardite

<img src="assets/wardite.svg" alt="Wardite logo" width="160">

[![Test CRuby and Spinel](https://github.com/udzura/wardite/actions/workflows/runtime-tests.yml/badge.svg)](https://github.com/udzura/wardite/actions/workflows/runtime-tests.yml) [![Test Wardite](https://github.com/udzura/wardite/actions/workflows/spec.yml/badge.svg)](https://github.com/udzura/wardite/actions/workflows/spec.yml) [![gem version](https://badge.fury.io/rb/wardite.svg)](https://rubygems.org/gems/wardite)

A pure-ruby webassembly runtime.

- [x] Fully typed by RBS (with the aid of [rbs-inline](https://github.com/soutaro/rbs-inline))
- [ ] WASI (p1) support

## Supported Instructions

ref: https://webassembly.github.io/spec/core/binary/instructions.html

- [x] Control Instructions
- [x] Parametric Instructions
- [x] Variable Instructions
- [ ] Table Instructions
- [x] Memory Instructions (except `data.drop`)
- [x] Numeric Instructions (`0x41 ... 0xC4`)
- [x] Numeric Instructions (`0xFC` Operations)
- [ ] Reference Instructions
- [ ] Vector Instructions
- [x] end `0x0B`

## Installation

Install the gem and add to the application's Gemfile by executing:

    $ bundle add wardite

If bundler is not being used to manage dependencies, install the gem by executing:

    $ gem install wardite

## Usage

- In your ruby code, instanciate Wardite runtime:

```ruby
require "wardite"

path = ARGV[0]
method = ARGV[1]
args = ARGV[2..-1] || []

instance = Wardite::new(path: path)
if method
  instance.runtime.call(method, args)
elsif instance.runtime.callable?("_start")
  instance.runtime.call("_start", [])
end
```

- Wardite bundles `wardite` cli command:

```console
$ wardite examples/test.wasm
#=> Test!
```

### Efflorescence register VM

The CLI and Ruby API use the MIR-based Efflorescence register VM. The
CRuby and Spinel CLIs still accept `--new-engine` for compatibility.

```sh
wardite --no-wasi --invoke add test/add.wasm 100 200
# return value: I32(300)
```

Ruby callers can omit the `engine:` keyword or pass `:efflorescence`. Efflorescence reports unsupported instructions with an explicit
exception. See the [design, supported subset and tests](docs/efflorescence.md)
and [benchmarks](benchmark/README.md).

Efflorescence now includes independent COPY/immediate/branch/fusion passes,
flat integer bytecode and frame reuse. Execution always uses flat bytecode,
including with `--mir-disable all`; there is no `flat` optimization switch.
Use `--mir-enable NAME` and `--mir-disable NAME` to select individual optimizations.
Both options are repeatable and accept `all`. An explicit disable takes precedence.
Use `--mir-dump` to inspect MIR and `--mir-profile` for counters.
See [Phase 2](docs/efflorescence-phase2.md) ([日本語](docs/efflorescence-phase2-ja.md)).

Pass `--mir-enable cse` or set `WARDITE_MIR_CSE=1` to try block-local common subexpression elimination
for integer operations. Use `--mir-disable cse` to turn it off in the same
environment. The experimental pass has its own MIR2 cache key.

For repeated i64 byte-table checks that share a branch target, `exit_copy`
moves constant assignments onto the taken edges. It is enabled by default.
The experimental `fold`, `cfg`, `dce`, and `licm` passes can be enabled
independently with `--mir-enable NAME`. Each combination has its own MIR2 key.
See [ADR 0028](docs/adr/0028-efflorescence-reduce-executed-instructions.md).
[ADR 0029](docs/adr/0029-efflorescence-spinel-interpreter-costs.md) covers byte-table lookup fusion, the Spinel pin, and comparisons with iwasm and Wasmtime.

On CRuby and Spinel, the default is to validate the whole module at load time
and prepare MIR on the first call to each function. For repeated runs, pass
`--mir-cache DIR`: the first run prepares all functions and writes the cache,
and later runs restore only the functions they call. Use a local directory you control. Each run still decodes
the Wasm, links imports, and initializes a fresh instance. `--mir-dump` and
`--mir-profile` build MIR normally. Ruby callers can pass `mir_cache: dir`.
CRuby and Spinel use different cache keys.

On a cold load, native Spinel translates modules with at least 32 defined
functions using up to eight workers, including the calling thread. Smaller
modules and CRuby use one worker by default. Set `WARDITE_MIR_WORKERS=1`
to force serial translation, or choose 2–8 to request parallel translation
even for a small module. `SPINEL_WORKERS` controls the underlying Spinel
scheduler and also sets the default MIR worker count (up to eight).
`WARDITE_TRACE=1` reports semantic MIR translation time on a cache miss.

The default `--mir-cache-verify checksum` checks the payload size and samples
blocks. Use `--mir-cache-verify sha256` or Ruby's `mir_cache_verify: :sha256`
to check the whole payload. Both modes use the same cache file. By default,
each function is restored and structurally checked before its first execution.
Use `--mir-eager` (also spelled `--mir-cache-eager`) or Ruby's
`mir_cache_eager: true` to prepare or restore every function at load time. If a lazy check fails, Wardite stops and reports the
cache path. Delete that file and rerun. Corruption outside the sampled blocks
can go undetected in checksum mode, including changes that leave the MIR
structurally valid.
[MIR2 cache measurements](docs/efflorescence-mir2-cache.md)

For WASI commands, `--snapshot DIR` (with `--mir-cache DIR`) saves
the guest state just before its first WASI call that reads files or writes output,
and later runs with the same Wasm, arguments, environment, preopens and stdio
kinds resume from there. Clock values and random bytes read before that point
are frozen into the snapshot, so every resumed run sees the same values (for Ruby, the same hash
seed). Do not use it where that matters, such as hashing untrusted keys.
[ADR 0012](docs/adr/0012-efflorescence-startup-snapshot.md)

[M1](docs/efflorescence-m1.md) adds the remaining basic i32 operations,
if/else/select/br_table, and new exception handling (try_table/throw/throw_ref).
Tags can carry numeric payloads. Nullable exnref locals and multi-result blocks carry
caught values. Uncaught exceptions expose their tag and payload through
`Wardite::UncaughtWasmException`. EH remains exclusive to Efflorescence.

[M2](docs/efflorescence-m2.md) adds i32 loads/stores, mutable i32 globals and
memory.size/grow/init/copy/fill. All state stays in the shared Store, with
checked byte ranges and instance-local runtime data segments.

[M3](docs/efflorescence-m3.md) adds i32 function imports, imported reexports,
and typed `call_indirect` through funcref table 0. Host callbacks share the
instance Store and can re-enter the VM. On CRuby, Efflorescence runs built-in
WASI `fd_write` and `proc_exit` with unboxed i32 arguments. Spinel supports
regular host callbacks.

[M4](docs/efflorescence-m4.md) adds i64 and integer conversions, including
mixed signatures, memory, globals and exception payloads. For an i64 result,
`runtime.call` returns a `Wardite::I64` and `runtime.call_unboxed` returns a
signed 64-bit Integer. The i32 unboxed result remains unsigned.

[M5](docs/efflorescence-m5.md) adds f32 and f64 arithmetic, conversions, memory,
globals, calls and exception payloads. Float arguments accept Ruby Float or the
matching wrapper. Float results are Ruby Float from `call_unboxed` and
`Wardite::F32` or `Wardite::F64` from `call`.

[M6](docs/efflorescence-m6.md) verifies the 188 opcodes in the M0 legacy coverage
baseline and three additional EH opcodes on CRuby and Spinel. Run
`bundle exec rake parity` with Spinel, wasm-tools and Wasmtime installed.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `bundle exec rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

Additionaly, you can run `bundle exec rake check` to generate rbs files from annotations and run `steep check`.

### Native executable with Spinel

A `spin.toml` application is also available under [`spinel/`](spinel/README.md),
using `lib/` as a local source dependency and the same CLI as the RubyGem.

With `spinel` and a C compiler on your PATH, build the existing CLI:

```console
$ make spinel
$ build/wardite --no-wasi --invoke add test/add.wasm 100 200
return value: I32(300)
$ make spinel-test
```

The executable enables the shared WASI Preview 1 host by default. Use
`--no-wasi` to disable it. To boot a Ruby 4.0.9 WASI binary, run
`build/wardite -- "$ruby_wasm" --disable-gems -e 'puts 6*7'`.
See the [ruby.wasm verification record](docs/efflorescence-ruby-wasm-phase1.md)
for the build and file-loading commands. Vernier profiling is available in the
CRuby build. In both builds, use `instance.runtime.call("add", [100, 200])`
to invoke an exported function and `instance.exports["memory"]` to look up an
exported memory.

The build leaves inline RBS and Spinel's default integer overflow checks enabled.
Wasm integer operations bound their intermediate values, so
`--int-overflow=promote` is not required.
CI and release builds pin Spinel commit `a64542970` from
[Spinel #12380](https://github.com/matz/spinel/pull/12380), which uses Arm SHA2
instructions to hash Wasm cache keys on supported AArch64 targets.
See the [build instructions and host memory API](docs/efflorescence-spinel-linear-memory.md).
Override `SPINEL`, `SPINELFLAGS`, `BUILD_DIR`, or `RUBY` when needed.

#### Experimental function JIT on macOS arm64

Set `WARDITE_MIR_JIT=1` before starting Wardite to try the AArch64 backend.
This example runs the same integer loop with or without the JIT:

```sh
wat2wasm benchmark/i32_mix.wat -o build/i32_mix.wasm
build/wardite --no-wasi --invoke inline_mix build/i32_mix.wasm 1000000 123
WARDITE_MIR_JIT=1 WARDITE_TRACE=1 build/wardite --no-wasi --invoke inline_mix build/i32_mix.wasm 1000000 123
```

On the first public call to a function, Wardite prepares its usual MIR.
The [Ruby emitter](lib/wardite/efflorescence/spinel_jit/aarch64.rb) translates
the whole function and resolves branches once it knows each instruction's
native offset. It accepts i32, i64, f32 and f64 parameters and one numeric
result. It supports i64 arithmetic and bit operations, scalar floating-point
arithmetic and comparisons, and integer/float conversions. Each floating-point
operation rounds at its Wasm width. The trial-division
`count_primes` benchmark uses a 64-bit square and an unsigned comparison.
The first 15 MIR slots live in registers and the remaining slots use an
aligned stack frame, up to 128 slots in total.

If execution reaches an integer zero divisor, signed division overflow, an
invalid or overflowing trapping float-to-integer conversion, an explicit
trap, or a direct call immediately followed by a trap, the interpreter replays the
function from its original arguments. All instructions executed natively
before replay affect only local values. Functions with other calls or memory
operations, calls from inside interpreted Wasm, and MIR profiling use the
interpreter.

The [Spinel adapter](lib/wardite/efflorescence/spinel_jit.rb) caches the machine
code bytes per VM and function. For each call it copies them into writable
pages, switches the pages to read/execute, calls the function, and releases
the mapping on return. The native function reads its arguments from 64-bit
buffer slots and writes its result to the first slot on success. Its return
status is separate from the Wasm result. A bailout leaves the buffer
untouched and keeps the compiled code for the next invocation.
A mapping failure disables the native entry for that function.

Run `ruby benchmark/measure_i64_jit.rb build/wardite` to compare the
`alu` and `division` loops with the JIT off and on. It checks both results
against Wasmtime and reports median whole-process times.

Run `ruby benchmark/measure_float_jit.rb build/wardite /path/to/mandelbrot.wasm`
for the f32 and f64 Mandelbrot exports from wardite-benches and Wardite's
`float_alu` and `float_convert` loops. The Wasm path is optional when
wardite-benches is built in the directory next to this checkout.

On an Apple Silicon Mac, run the full regression suite with:

```sh
bin/test-spinel-jit
```

Use native arm64 Ruby with the bundle installed, Spinel, `wasm-tools`, and
the Xcode Command Line Tools. The script builds the CLI, checks that
integer loops run as native code and that trap and fallback paths work, then
runs `rake test` with `WARDITE_MIR_JIT=1` and the native binary available to
all Spinel E2E tests. Incremental build objects are reused across runs under
`build/spinel-jit-test/objects` by default.

#### Build release executables on macOS

With Zig 0.17.1, Ruby, and the Xcode Command Line Tools installed, run:

```sh
make spinel-zig
```

The first build downloads and builds the same Spinel revision used in CI.
It builds the Spinel runtime and native StringIO code for each target.
On a local Apple Silicon Mac, the macOS arm64 executable is compiled and
linked with Apple Clang. To build just that executable without installing Zig,
run `make spinel-zig ZIG_TARGETS=aarch64-macos`. Linux targets use Zig.
On Intel Macs and in CI (when `CI` or `GITHUB_ACTIONS` is set), all targets use Zig.

| Target | Executable |
| --- | --- |
| macOS arm64 | `build/spinel-zig/aarch64-macos.13.0/wardite` |
| Linux x86_64 | `build/spinel-zig/x86_64-linux-gnu.2.28/wardite` |
| Linux arm64 | `build/spinel-zig/aarch64-linux-gnu.2.28/wardite` |

Linux builds dynamically link the target system's glibc. The default glibc
baseline is 2.28 and the macOS deployment target is 13.0. Set `ZIG_GLIBC`
or `ZIG_MACOS` to change those values. Use `ZIG` to select the compiler,
`ZIG_JOBS` to set parallelism, or `ZIG_TARGETS` to build a subset:

```sh
make spinel-zig ZIG=/opt/homebrew/bin/zig ZIG_TARGETS=x86_64-linux
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/udzura/wardite.

## See also

- https://github.com/technohippy/wasmrb
  - Referencial implementation but no support with WASI
  - Wardite aims to support full WASI (preview 1)
- https://github.com/skanehira/chibiwasm
  - Small and consise implementation in Rust
  - Wardite was first built upon [its development tutorial](https://skanehira.github.io/writing-a-wasm-runtime-in-rust/). Thanks!
  - Many of test wat files under [`examples/`](./examples/) are borrowed from chibiwasm project
