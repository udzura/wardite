# frozen_string_literal: true

require "test_helper"
require_relative "support/efflorescence_helper"
require_relative "support/efflorescence_m4_cases"

class EfflorescenceM4HostTest < Test::Unit::TestCase
  include EfflorescenceHelper
  include EfflorescenceM4Cases

  test "typed host arguments, reexports, indirect calls and reentry" do
    vm = nil
    observed = []
    env = {
      mix: ->(_store, args) do
        left, mode, right = args
        observed << args
        assert_equal [Wardite::I64, Wardite::I32, Wardite::I64], args.map(&:class)
        assert_equal 9, right.value
        case mode.value
        when 0 then left.value_s - right.value_s
        when 1 then vm.call("echo", [left])
        when 2
          assert_raise(Wardite::Unreachable) { vm.call_unboxed("fail", []) }
          Wardite::I64(-1)
        when 3 then Wardite::I32(1)
        when 4 then Wardite::F64(0)
        else raise "unexpected host mode"
        end
      end,
      zero: ->(_store, args) { assert_empty args; Wardite::I64(-1) },
      one: ->(_store, args) { assert_equal(-1, args.fetch(0).value_s); Wardite::I32(17) },
      sink: ->(_store, args) { assert_equal 1, args.size; args[0].value_s.zero? ? nil : Wardite::I64(-1) }
    }
    vm = load_efflorescence(HOST_WAT, import_object: { env: env }, mir_profile: true).runtime
    assert_equal [[:i64, :i32, :i64], [:i64, :i32, :i64]], vm.instance.types.take(2).map(&:callsig)
    assert_equal(-1, vm.call_unboxed("zero", []))
    assert_equal 17, vm.call_unboxed("one", [-1])
    assert_nil vm.call_unboxed("sink", [0])
    assert_raise_message(/host ABI result mismatch/) { vm.call_unboxed("sink", [1]) }
    assert_equal(-10, vm.call_unboxed("mix", [-1, 0, 9]))
    assert_equal(-10, vm.call_unboxed("direct", [-1, 0]))
    assert_equal(-10, vm.call_unboxed("indirect", [0, -1, 0]))
    assert_equal(-10, vm.call_unboxed("indirect", [1, -1, 0]))
    assert_raise_message(/function type mismatch/) { vm.call_unboxed("indirect", [2, -1, 0]) }
    assert_raise_message(/null reference/) { vm.call_unboxed("indirect", [3, -1, 0]) }
    assert_equal 0, vm.call_unboxed("outer", [-2**63, 1])
    assert_equal 1, vm.metrics.host_calls
    assert_equal 2, vm.metrics.function_entries
    assert_equal 0, vm.call_unboxed("outer", [-1, 2])
    assert_equal 1, vm.metrics.host_calls
    calls = observed.size
    [3, 4].each do |mode|
      assert_raise_message(/host ABI result mismatch/) { vm.call_unboxed("direct", [-1, mode]) }
    end
    assert_equal calls + 2, observed.size
    assert_equal(-1, vm.call_unboxed("echo", [-1]))
  end

  test "path_open uses the boxed ABI for i64 rights and writes the opened fd" do
    Dir.mktmpdir("wardite-m4-wasi") do |dir|
      File.write(File.join(dir, "sample"), "m4")
      bytes = compile_efflorescence_wat(WASI_PATH_OPEN_WAT)
      instance = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), engine: :efflorescence)
      wasi = instance.wasi
      wasi.set_preopened_dir(dir, dir)
      vm = instance.runtime
      assert_nil vm.ir.hosts.fetch(0).unboxed_wasi
      memory = instance.store.memories.fetch(0).data
      memory[32, 4] = [0xffffffff].pack("V")
      assert_equal Wardite::Wasi::ENOENT, vm.call_unboxed("open", [16])
      assert_equal 0xffffffff, memory.byteslice(32, 4).unpack1("V")
      assert_equal 0, vm.call_unboxed("open", [0])
      fd = memory.byteslice(32, 4).unpack1("V")
      assert_equal 4, fd
      file = wasi.fd_table.fetch(fd)
      begin
        assert_equal "m4", file.read
      ensure
        file.close
      end
    end
  end
end
