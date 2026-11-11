# frozen_string_literal: true

require 'test_helper'
require_relative 'support/efflorescence_helper'
require_relative 'support/efflorescence_m2_cases'

class EfflorescenceM2BulkTest < Test::Unit::TestCase
  include EfflorescenceHelper
  include EfflorescenceM2Cases
  E = Wardite::Efflorescence

  def instance(bytes, **options)
    Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), engine: :efflorescence, enable_wasi: false, **options)
  end

  def unchanged_trap(fresh, name, arguments)
    memory = fresh.store.memories[0]
    before = [memory.data.dup, memory.data.bytesize, memory.current]
    assert_raise(Wardite::EvalError) { fresh.runtime.call_unboxed(name, arguments) }
    assert_equal before, [memory.data, memory.data.bytesize, memory.current], "#{name} #{arguments}"
  end

  test 'copy handles both overlap directions self-copy and zero-length boundaries without partial writes' do
    bytes = compile_efflorescence_wat(BULK_WAT)
    MODES.each do |mode|
      fresh = instance(bytes, **mode)
      vm = fresh.runtime
      memory = fresh.store.memories[0]
      [[2, 0, 8, '0101234567abcdef'], [0, 2, 8, '2345678989abcdef'], [0, 0, 16, '0123456789abcdef']].each do |dst, src, length, expected|
        memory.data[0,16] = '0123456789abcdef'.b
        vm.call_unboxed('copy', [dst, src, length])
        assert_equal expected.b, memory.data.byteslice(0,16)
      end
      before = memory.data.dup
      [[65536,0,0], [0,65536,0], [65536,65536,0], [0,0,65536]].each do |args|
        vm.call_unboxed('copy', args)
        assert_equal before, memory.data
      end
      [[0,65535,2], [65535,0,2], [0,65537,0], [65537,0,0], [0,-1,1], [-1,0,1], [0,0,-1]].each do |args|
        unchanged_trap(fresh, 'copy', args)
      end
      assert_equal 65536, memory.data.bytesize
      assert_equal 1, memory.current
    end
  end

  test 'fill masks the byte and validates the whole destination including zero-length endpoints' do
    bytes = compile_efflorescence_wat(BULK_WAT)
    MODES.each do |mode|
      fresh = instance(bytes, **mode)
      memory = fresh.store.memories[0]
      [0,255,256,0xffffffff].each do |value|
        fresh.runtime.call_unboxed('fill', [1,value,7])
        assert_equal [value & 255] * 7, memory.data.byteslice(1,7).bytes
        fresh.runtime.call_unboxed('fill', [65535,value,1])
        assert_equal value & 255, memory.data.getbyte(65535)
        before = memory.data.dup
        fresh.runtime.call_unboxed('fill', [65536,value,0])
        assert_equal before, memory.data
      end
      [[65537,0,0], [65535,42,2], [-1,42,1], [0,42,-1]].each { |args| unchanged_trap(fresh, 'fill', args) }
      assert_equal Encoding::BINARY, memory.data.encoding
    end
  end

  test 'passive runtime segments are reusable and instance-local while active segments are consumed' do
    bytes = compile_efflorescence_wat(BULK_WAT)
    MODES.each do |mode|
      fresh = instance(bytes, **mode)
      other = instance(bytes, **mode)
      memory = fresh.store.memories[0]
      assert_equal 'abcdef'.b, memory.data.byteslice(0,6)
      assert_equal ['', "\x80\xffABC\0xyz".b, ''].map(&:b), fresh.store.data_segments
      assert_not_same fresh.store.data_segments[1], other.store.data_segments[1]
      assert_not_same fresh.data_section.segments[1].data, fresh.store.data_segments[1]
      [100,200,65527].each do |dst|
        fresh.runtime.call_unboxed('init', [dst,0,9])
        assert_equal "\x80\xffABC\0xyz".b, memory.data.byteslice(dst,9)
      end
      [[65536,9,0], [0,0,0]].each { |args| fresh.runtime.call_unboxed('init', args) }
      fresh.runtime.call_unboxed('empty', [65536,0,0])
      fresh.runtime.call_unboxed('active', [65536,0,0])
      [['init',[0,8,2]], ['init',[65528,0,9]], ['init',[0,10,0]], ['init',[65537,0,0]],
       ['empty',[0,0,1]], ['empty',[0,1,0]], ['active',[0,0,1]], ['active',[0,1,0]]].each do |name, args|
        unchanged_trap(fresh, name, args)
      end
      assert_equal 'abcdef'.b, memory.data.byteslice(0,6)
      assert_equal "\x80\xffABC\0xyz".b, fresh.store.data_segments[1]
      assert_equal "\0".b * 9, other.store.memories[0].data.byteslice(100,9)
    end
  end

  test 'fill writes across multiple chunks and preserves both ends' do
    bytes = compile_efflorescence_wat(<<~WAT)
      (module (memory 3)
        (func (export "fill") (param i32 i32 i32)
          local.get 0 local.get 1 local.get 2 memory.fill))
    WAT
    MODES.each do |mode|
      fresh = instance(bytes, **mode)
      memory = fresh.store.memories.fetch(0)
      length = 2 * 65536 + 7
      memory.data.setbyte(2, 42)
      memory.data.setbyte(3 + length, 43)
      fresh.runtime.call_unboxed('fill', [3, 0x180, length])
      assert_equal "\x80".b * length, memory.data.byteslice(3, length)
      assert_equal [42, 43], [memory.data.getbyte(2), memory.data.getbyte(3 + length)]
      assert_equal 3 * 65536, memory.data.bytesize
      unchanged_trap(fresh, 'fill', [65535, 1, length])

      # A caller can replace the backing String through the Store API.
      memory.data = +"日本語"
      fresh.runtime.call_unboxed('fill', [2, 0xff, 1])
      assert_equal [0xe6, 0x97, 0xff, 0xe6], memory.data.bytes.first(4)
      assert_equal Encoding::UTF_8, memory.data.encoding
    end
  end

  test 'ordinary bulk operations agree with the stack VM in independent Stores' do
    bytes = compile_efflorescence_wat(BULK_WAT)
    MODES.each do |mode|
      fresh = instance(bytes, **mode)
      old = Wardite::BinaryLoader.load_from_buffer(StringIO.new(bytes), enable_wasi: false)
      [['init',[20,0,9]], ['copy',[22,20,7]], ['copy',[20,22,7]], ['fill',[17,42,3]]].each do |name,args|
        fresh.runtime.call_unboxed(name,args)
        old.runtime.call(name,args)
        assert_equal old.store.memories[0].data, fresh.store.memories[0].data
        assert_equal old.store.memories[0].current, fresh.store.memories[0].current
      end
    end
  end

  test 'bulk profiling counts all three table reads and preserves the original tables' do
    fresh = load_efflorescence(BULK_WAT, mir_profile: true)
    vm = fresh.runtime
    before = vm.semantic_ir.functions.map { |fn| fn.memory_sites.map { |site| site.sources.dup } }
    vm.call_unboxed('copy',[0,0,0])
    assert_equal 3, vm.metrics.register_reads
    assert_equal 0, vm.metrics.register_writes
    assert_equal 2, vm.metrics.dispatches
    assert_equal before, vm.semantic_ir.functions.map { |fn| fn.memory_sites.map { |site| site.sources.dup } }
    vm.ir.functions.each_with_index do |fn,i|
      fn.memory_sites.each_with_index { |site,j| assert_not_same site, vm.semantic_ir.function_at(i).memory_sites[j] }
    end
    assert_include vm.dump_mir, 'memory 0:'
    assert_include vm.dump_mir, 'data=1'
  end

  test 'bad bulk types indices and unsupported data.drop fail without an external validator' do
    ['(module (memory 1) (func (local exnref) local.get 0 i32.const 0 i32.const 0 memory.copy))',
     '(module (memory 1) (func unreachable memory.copy 1 0))',
     '(module (memory 1) (func unreachable memory.fill 1))'].each do |wat|
      assert_raise(E::TranslationError, E::UnsupportedFeature) { load_efflorescence(wat) }
    end
    assert_raise(E::UnsupportedFeature) { load_efflorescence('(module (data "x") (func unreachable data.drop 0))') }
    fn = E::Function.new(0, [:i32, :i32], [], 0)
    fn.memory_sites << E::MemorySite.new([0,1])
    fn.instructions << E::Instruction.new([E::Opcode::MEMORY_COPY,0])
    fn.instructions << E::Instruction.new([E::Opcode::RETURN,-1])
    assert_raise(E::TranslationError) { E::RegisterValidation.new.validate(fn) }
    fn.instructions[0] = E::Instruction.new([E::Opcode::MEMORY_COPY,-1])
    assert_raise(E::TranslationError) { E::RegisterValidation.new.validate(fn) }
  end
end
