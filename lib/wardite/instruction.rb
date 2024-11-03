# rbs_inline: enabled

module Wardite
  class Op
    # @see https://pengowray.github.io/wasm-ops/
    SYMS = %i[
      unreachable nop block loop if else try catch
      throw rethrow throw_ref end br br_if br_table return
      call call_indirect return_call return_call_indirect call_ref return_call_ref __undef__ __undef__
      delegate catch_all drop select select_t __undef__ __undef__ try_table
      local_get local_set local_tee global_get global_set table_get table_set __undef__
      i32_load i64_load f32_load f64_load i32_load8_s i32_load8_u i32_load16_s i32_load16_u
      i64_load8_s i64_load8_u i64_load16_s i64_load16_u i64_load32_s i64_load32_u i32_store i64_store
      f32_store f64_store i32_store8 i32_store16 i64_store8 i64_store16 i64_store32 memory_size
      memory_grow i32_const i64_const f32_const f64_const i32_eqz i32_eq i32_ne
      i32_lts i32_ltu i32_gts i32_gtu i32_les i32_leu i32_ges i32_geu
      i64_eqz i64_eq i64_ne i64_lts i64_ltu i64_gts i64_gtu i64_les
      i64_leu i64_ges i64_geu f32_eq f32_ne f32_lt f32_gt f32_le
      f32_ge f64_eq f64_ne f64_lt f64_gt f64_le f64_ge i32_clz
      i32_ctz i32_popcnt i32_add i32_sub i32_mul i32_div_s i32_div_u i32_rem_s
      i32_rem_u i32_and i32_or i32_xor i32_shl i32_shr_s i32_shr_u i32_rotl
      i32_rotr i64_clz i64_ctz i64_popcnt i64_add i64_sub i64_mul i64_div_s
      i64_div_u i64_rem_s i64_rem_u i64_and i64_or i64_xor i64_shl i64_shr_s
      i64_shr_u i64_rotl i64_rotr f32_abs f32_neg f32_ceil f32_floor f32_trunc
      f32_nearest f32_sqrt f32_add f32_sub f32_mul f32_div f32_min f32_max
      f32_copysign f64_abs f64_neg f64_ceil f64_floor f64_trunc f64_nearest f64_sqrt
      f64_add f64_sub f64_mul f64_div f64_min f64_max f64_copysign i32_wrap_i64
      i32_trunc_f32_s i32_trunc_f32_u i32_trunc_f64_s i32_trunc_f64_u i64_extend_i32_s i64_extend_i32_u i64_trunc_f32_s i64_trunc_f32_u
      i64_trunc_f64_s i64_trunc_f64_u f32_convert_i32_s f32_convert_i32_u f32_convert_i64_s f32_convert_i64_u f32_demote_f64 f64_convert_i32_s
      f64_convert_i32_u f64_convert_i64_s f64_convert_i64_u f64_promote_f32 i32_reinterpret_f32 i64_reinterpret_f64 f32_reinterpret_i32 f64_reinterpret_i64
      __unsuported_from_here_on__
    ] #: Array[Symbol]

    # @rbs @@table: Hash[Integer, Symbol] | nil
    @@table = nil 

    # @rbs return: Hash[Integer, Symbol]
    def self.table
      @@table if @@table != nil
      @@table = {}.tap do |ha|
        SYMS.each_with_index do |sym, i|
          ha[i] = sym
        end
      end
      @@table
    end

    attr_accessor :namespace #: Symbol

    attr_accessor :code #: Symbol

    # TODO: add types of potential operands
    attr_accessor :operand #: Array[Integer|Float|Block]

    # @rbs namespace: Symbol
    # @rbs code: Symbol
    # @rbs operand: Array[Integer|Float|Block]
    def initialize(namespace, code, operand)
      @namespace = namespace      
      @code = code
      @operand = operand
    end

    # @rbs chr: String
    # @rbs return: [Symbol, Symbol]
    def self.to_sym(chr)
      code = table[chr.ord]
      if ! code
        raise "found unknown code 0x#{chr.ord.to_s(16)}"
      end
      # opcodes equal to or larger than are "convert" ops
      if chr.ord >= 0xa7
        return [:convert, code]
      end

      prefix = code.to_s.split("_")[0]
      case prefix
      when "i32", "i64", "f32", "f64"
        [prefix.to_sym, code]
      else
        [:default, code]
      end
    end

    # @rbs chr: Symbol
    # @rbs return: Array[Symbol]
    def self.operand_of(code)
      case code
      when :local_get, :local_set, :call
        [:u32]
      when :i32_const
        [:i32]
      when :i32_store
        [:u32, :u32]
      when :if
        [:u8_block]
      else
        []
      end
    end

    # @see https://www.w3.org/TR/wasm-core-1/#value-types%E2%91%A2
    # @rbs code: Integer
    # @rbs return: Symbol
    def self.i2type(code)
      case code
      when 0x7f
        :i32
      when 0x7e
        :i64
      when 0x7d
        :f32
      when 0x7c
        :f64
      else
        raise "unknown type code #{code}"
      end
    end
  end
end