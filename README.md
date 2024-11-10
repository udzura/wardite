# Wardite

[![workflow](https://github.com/udzura/wardite/actions/workflows/main.yml/badge.svg)](https://github.com/udzura/wardite/actions) [![gem version](https://badge.fury.io/rb/wardite.svg)](https://rubygems.org/gems/wardite)

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

instance = Wardite::new(path: path);
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

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `bundle exec rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

Additionaly, you can run `bundle exec rake check` to generate rbs files from annotations and run `steep check`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/udzura/wardite.

## See also

- https://github.com/technohippy/wasmrb?tab=readme-ov-file
  - Referencial implementation but no support with WASI
  - Wardite aims to support full WASI (previwe 1)
- https://github.com/skanehira/chibiwasm
  - Small and consise implementation in Rust
  - Wardite was first built upon [its development tutorial](https://skanehira.github.io/writing-a-wasm-runtime-in-rust/). Thanks!
  - Many of test wat files under [`examples/`](./examples/) are borrowed from chibiwasm project