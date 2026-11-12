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
if !method && instance.runtime.respond_to?(:_start)
  instance.runtime._start
else
  instance.runtime.call(method, args)
end
```

- Wardite bundles `wardite` cli command:

```console
$ wardite examples/test.wasm
#=> Test!
```

### Efflorescence register VM (experimental)

Use `--new-engine` to select the MIR-based register engine. The stack VM is the
default. The same option is available in Spinel builds.

```sh
wardite --new-engine --no-wasi --invoke add test/add.wasm 100 200
# return value: I32(300)
```

In Ruby, pass `engine: :efflorescence` to `Wardite.new` or
`BinaryLoader.load_from_buffer`. Unsupported instructions raise an explicit
exception. See the [design, supported subset and tests](docs/efflorescence.md)
and [engine comparison benchmark](benchmark/README.md).

Efflorescence now includes independent COPY/immediate/branch/fusion passes,
flat integer bytecode and frame reuse. Execution always uses flat bytecode,
including with `--mir-disable all`; there is no `flat` optimization switch.
Use `--mir-disable NAME` to compare
individual features, `--mir-dump` to inspect MIR and `--mir-profile` for counters.
See [Phase 2](docs/efflorescence-phase2.md) ([日本語](docs/efflorescence-phase2-ja.md)).

On CRuby and Spinel, pass `--mir-cache DIR` with `--new-engine` to reuse lowered
MIR across processes. Use a local directory you control. Each run still decodes
the Wasm, links imports, and initializes a fresh instance. `--mir-dump` and
`--mir-profile` build MIR normally. Ruby callers can pass `mir_cache: dir` with
`engine: :efflorescence`. CRuby and Spinel use different cache keys.
[MIR2 cache measurements](docs/efflorescence-mir2-cache.md)

For WASI commands, `--snapshot DIR` (with `--new-engine --mir-cache DIR`) saves
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
`build/wardite --new-engine -- "$ruby_wasm" --disable-gems -e 'puts 6*7'`.
See the [ruby.wasm verification record](docs/efflorescence-ruby-wasm-phase1.md)
for the build and file-loading commands. Vernier profiling is available in the
CRuby build. Ruby's dynamic export helpers (`instance.add(...)` and
`runtime.add(...)`) rely on `method_missing`; use `instance.runtime.call("add",
[100, 200])` when compiling an application with Spinel.

The build leaves inline RBS and Spinel's default integer overflow checks enabled.
Wasm integer operations bound their intermediate values, so
`--int-overflow=promote` is not required.
The pinned Spinel build applies the IO::Buffer patches under `spinel/patches`.
See the [build instructions and host memory API](docs/efflorescence-spinel-linear-memory.md).
Override `SPINEL`, `SPINELFLAGS`, `BUILD_DIR`, or `RUBY` when needed.

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
