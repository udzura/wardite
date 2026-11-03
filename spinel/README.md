# Build with spin

This directory is a Spinel application using Wardite's existing `lib/` as a
local source dependency. Its executable uses the same CLI class as `exe/wardite`.
Keeping the application here avoids having spin automatically seed the compiler
with the RubyGem's `sig/` files or discover its test-unit tests as spin snapshots.

With spin `2026.10.25+1967` (`6e7fc1355`), run from this directory:

```sh
spin build wardite -- --no-inline-rbs --int-overflow=promote
./build/bin/wardite --no-wasi --invoke add ../test/add.wasm 100 200
# return value: I32(300)
```

This spin version accepts extra compiler flags after `spin build --`, but has
no manifest field for compiler flags. Always pass the flags above when building:
`--no-inline-rbs` leaves Wardite's rbs-inline annotations to the Ruby tooling,
and `--int-overflow=promote` preserves Ruby's arbitrary-precision integer
arithmetic used by Wasm numeric operations. A bare `spin run` may rebuild without
these flags, so invoke the built executable directly.

`spin test` uses standalone programs or snapshots rather than test-unit. To run
the existing native regression tests against this binary, use the following
from the repository root after building:

```sh
WARDITE_SPINEL_BIN="$PWD/spinel/build/bin/wardite" bundle exec ruby -Ilib:test test/e2e/spinel_test.rb
```

The repository's `make spinel` and `make spinel-test` commands remain available
and handle the required compiler flags automatically.
