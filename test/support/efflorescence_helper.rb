# frozen_string_literal: true

require "open3"

module EfflorescenceHelper
  MIX_WAT = File.expand_path("../../benchmark/i32_mix.wat", __dir__)
  MIX_CASES = [[0, 0], [0, 123], [1, 0], [1, 123], [10, 123],
               [1000, 123], [1000, 0xffffffff], [100000, 123]].freeze

  # Both branch arms write a result temporary, but only the first invocation
  # writes the two non-parameter locals. Recursive calls retain a live local.
  RESET_WAT = <<~WAT.freeze
    (module
      (func $leaf (param i32 i32) (result i32) (local i32 i32)
        block
          local.get 0 i32.eqz br_if 0
          local.get 1 local.set 2
          i32.const 99 local.set 3
        end
        local.get 2 local.get 3 i32.add
        block (result i32)
          local.get 1 i32.const 13 i32.shr_u
          local.get 0 br_if 0
          drop local.get 1 i32.const 7 i32.shl
        end
        i32.xor)
      (func $sum (param i32) (result i32) (local i32)
        block
          local.get 0 br_if 0
          local.get 1 return
        end
        local.get 0 local.set 1
        local.get 0 i32.const 1 i32.sub call $sum
        local.get 1 i32.add)
      (func (export "run") (param i32) (result i32)
        i32.const 1 local.get 0 call $leaf drop
        i32.const 0 local.get 0 call $leaf)
      (func (export "recursive") (param i32) (result i32)
        local.get 0 call $sum
        i32.const 0 call $sum i32.add
        local.get 0 call $sum i32.add)
      (func (export "fail")
        i32.const 1 i32.const 123 call $leaf drop
        unreachable))
  WAT

  CALL_PROTOCOL_WAT = <<~WAT.freeze
    (module
      (func $zero (result i32) i32.const 17)
      (func $one (param i32) (result i32) local.get 0 i32.const 1 i32.add)
      (func $many (param i32 i32 i32) (result i32)
        local.get 0 i32.const 11 i32.mul
        local.get 1 i32.const 3 i32.mul i32.sub
        local.get 2 i32.add)
      (func $void (param i32 i32)
        block
          local.get 0 local.get 1 i32.xor i32.eqz br_if 0
          unreachable
        end)
      (func $empty)
      (func (export "run") (param i32) (result i32)
        call $empty
        local.get 0 local.get 0 call $void
        call $zero
        local.get 0 call $one i32.add
        local.get 0
        local.get 0 i32.const 1 i32.add
        local.get 0 i32.const 2 i32.add
        call $many i32.xor)
      (func (export "alias") (param i32) (result i32)
        local.get 0
        local.get 0 call $one local.set 0
        local.get 0 i32.sub)
      (func $a (param i32) (result i32) (local i32)
        block
          local.get 0 br_if 0
          local.get 1 i32.const 7 i32.add return
        end
        local.get 0 local.set 1
        local.get 0 i32.const 1 i32.sub call $b
        local.get 1 i32.add)
      (func $b (param i32) (result i32) (local i32)
        block
          local.get 0 br_if 0
          local.get 1 i32.const 7 i32.add return
        end
        local.get 0 local.set 1
        local.get 0 i32.const 1 i32.sub call $a
        local.get 1 i32.add)
      (func (export "mutual") (param i32) (result i32)
        local.get 0 call $a
        i32.const 0 call $a i32.add
        i32.const 3 call $b i32.add))
  WAT

  INLINE_WAT = <<~WAT.freeze
    (module
      (func $mutate (param i32 i32) (result i32)
        local.get 0 local.get 1 local.set 0 local.get 0 i32.sub)
      (func $local (param i32) (result i32) (local i32)
        local.get 1 local.get 0 local.set 1 local.get 1 i32.add)
      (func $constant (result i32) i32.const -1)
      (func $void (param i32)
        local.get 0 i32.const 10 local.set 0 drop)
      (func $empty)
      (func (export "snapshot") (param i32) (result i32)
        local.get 0
        local.get 0 local.get 0 i32.const 1 i32.add call $mutate local.set 0
        local.get 0 i32.sub)
      (func (export "loop") (param i32 i32) (result i32) (local i32)
        block $done
          loop $repeat
            local.get 0 i32.eqz br_if $done
            local.get 2 local.get 1 call $local i32.add local.set 2
            local.get 0 i32.const 1 i32.sub local.set 0 br $repeat
          end
        end
        local.get 2)
      (func (export "constant") (result i32) call $constant)
      (func (export "void") (param i32) (result i32)
        call $empty local.get 0 call $void local.get 0)
      (func (export "branch") (param i32 i32) (result i32)
        block local.get 0 br_if 0 i32.const 99 local.set 1 end
        local.get 1 call $local))
  WAT

  # Independent arithmetic reference: modulo rather than MIR register operations.
  def reference_mix(rounds, seed)
    x = seed % (2**32)
    rounds.times do
      x ^= x / (2**13)
      x = (x * 1664525 + 1013904223) % (2**32)
      x = (x ^ (x * (2**7))) % (2**32)
    end
    x
  end

  def compile_efflorescence_wat(code)
    Dir.mktmpdir("wardite-efflorescence") do |dir|
      wat = File.join(dir, "input.wat")
      wasm = File.join(dir, "input.wasm")
      File.write(wat, code)
      output, status = Open3.capture2e("wasm-tools", "parse", wat, "-o", wasm)
      raise "WAT compilation failed: #{output}" unless status.success?
      File.binread(wasm)
    end
  end

  def load_efflorescence(code, **options)
    Wardite::BinaryLoader.load_from_buffer(
      StringIO.new(compile_efflorescence_wat(code)), enable_wasi: false, engine: :efflorescence, **options
    )
  end
end
