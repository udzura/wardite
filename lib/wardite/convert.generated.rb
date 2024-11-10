# rbs_inline: enabled
require_relative "value"

module Wardite
  module Evaluator
    # @rbs runtime: Runtime
    # @rbs frame: Frame
    # @rbs insn: Op
    # @rbs return: void 
    def self.convert_eval_insn(runtime, frame, insn)
      case insn.code

      when :i32_wrap_i64
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I64)
        to = from.wrap(to: :i32)
        raise EvalError, "failed to convert type" if !to.is_a?(I32)
        runtime.stack.push(to)


      when :i32_trunc_f32_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F32)
        to = from.trunc_s(to: :i32)
        raise EvalError, "failed to convert type" if !to.is_a?(I32)
        runtime.stack.push(to)


      when :i32_trunc_f64_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F64)
        to = from.trunc_s(to: :i32)
        raise EvalError, "failed to convert type" if !to.is_a?(I32)
        runtime.stack.push(to)


      when :i32_trunc_f32_u
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F32)
        to = from.trunc_u(to: :i32)
        raise EvalError, "failed to convert type" if !to.is_a?(I32)
        runtime.stack.push(to)


      when :i32_trunc_f64_u
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F64)
        to = from.trunc_u(to: :i32)
        raise EvalError, "failed to convert type" if !to.is_a?(I32)
        runtime.stack.push(to)


      when :i32_reinterpret_f32
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F32)
        to = from.reinterpret(to: :i32)
        raise EvalError, "failed to convert type" if !to.is_a?(I32)
        runtime.stack.push(to)


      when :i32_extend_8_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I32)
        to = from.extendN_s(to: :i32, from: :i8)
        raise EvalError, "failed to convert type" if !to.is_a?(I32)
        runtime.stack.push(to)


      when :i32_extend_16_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I32)
        to = from.extendN_s(to: :i32, from: :i16)
        raise EvalError, "failed to convert type" if !to.is_a?(I32)
        runtime.stack.push(to)


      when :i32_trunc_sat_f32_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F32)
        to = from.trunc_sat_s(to: :i32)
        raise EvalError, "failed to convert type" if !to.is_a?(I32)
        runtime.stack.push(to)


      when :i32_trunc_sat_f64_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F64)
        to = from.trunc_sat_s(to: :i32)
        raise EvalError, "failed to convert type" if !to.is_a?(I32)
        runtime.stack.push(to)


      when :i32_trunc_sat_f32_u
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F32)
        to = from.trunc_sat_u(to: :i32)
        raise EvalError, "failed to convert type" if !to.is_a?(I32)
        runtime.stack.push(to)


      when :i32_trunc_sat_f64_u
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F64)
        to = from.trunc_sat_u(to: :i32)
        raise EvalError, "failed to convert type" if !to.is_a?(I32)
        runtime.stack.push(to)


      when :i64_extend_i32_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I32)
        to = from.extend_s(to: :i64)
        raise EvalError, "failed to convert type" if !to.is_a?(I64)
        runtime.stack.push(to)


      when :i64_extend_i64_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I64)
        to = from.extend_s(to: :i64)
        raise EvalError, "failed to convert type" if !to.is_a?(I64)
        runtime.stack.push(to)


      when :i64_extend_i32_u
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I32)
        to = from.extend_u(to: :i64)
        raise EvalError, "failed to convert type" if !to.is_a?(I64)
        runtime.stack.push(to)


      when :i64_extend_i64_u
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I64)
        to = from.extend_u(to: :i64)
        raise EvalError, "failed to convert type" if !to.is_a?(I64)
        runtime.stack.push(to)


      when :i64_trunc_f32_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F32)
        to = from.trunc_s(to: :i64)
        raise EvalError, "failed to convert type" if !to.is_a?(I64)
        runtime.stack.push(to)


      when :i64_trunc_f64_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F64)
        to = from.trunc_s(to: :i64)
        raise EvalError, "failed to convert type" if !to.is_a?(I64)
        runtime.stack.push(to)


      when :i64_trunc_f32_u
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F32)
        to = from.trunc_u(to: :i64)
        raise EvalError, "failed to convert type" if !to.is_a?(I64)
        runtime.stack.push(to)


      when :i64_trunc_f64_u
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F64)
        to = from.trunc_u(to: :i64)
        raise EvalError, "failed to convert type" if !to.is_a?(I64)
        runtime.stack.push(to)


      when :i64_reinterpret_f64
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F64)
        to = from.reinterpret(to: :i64)
        raise EvalError, "failed to convert type" if !to.is_a?(I64)
        runtime.stack.push(to)


      when :i64_extend_8_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I32)
        to = from.extendN_s(to: :i64, from: :i8)
        raise EvalError, "failed to convert type" if !to.is_a?(I64)
        runtime.stack.push(to)


      when :i64_extend_16_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I32)
        to = from.extendN_s(to: :i64, from: :i16)
        raise EvalError, "failed to convert type" if !to.is_a?(I64)
        runtime.stack.push(to)


      when :i64_extend_32_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I32)
        to = from.extendN_s(to: :i64, from: :i32)
        raise EvalError, "failed to convert type" if !to.is_a?(I64)
        runtime.stack.push(to)


      when :i64_trunc_sat_f32_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F32)
        to = from.trunc_sat_s(to: :i64)
        raise EvalError, "failed to convert type" if !to.is_a?(I64)
        runtime.stack.push(to)


      when :i64_trunc_sat_f64_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F64)
        to = from.trunc_sat_s(to: :i64)
        raise EvalError, "failed to convert type" if !to.is_a?(I64)
        runtime.stack.push(to)


      when :i64_trunc_sat_f32_u
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F32)
        to = from.trunc_sat_u(to: :i64)
        raise EvalError, "failed to convert type" if !to.is_a?(I64)
        runtime.stack.push(to)


      when :i64_trunc_sat_f64_u
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F64)
        to = from.trunc_sat_u(to: :i64)
        raise EvalError, "failed to convert type" if !to.is_a?(I64)
        runtime.stack.push(to)


      when :f32_convert_i32_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I32)
        to = from.convert_s(to: :f32)
        raise EvalError, "failed to convert type" if !to.is_a?(F32)
        runtime.stack.push(to)


      when :f32_convert_i64_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I64)
        to = from.convert_s(to: :f32)
        raise EvalError, "failed to convert type" if !to.is_a?(F32)
        runtime.stack.push(to)


      when :f32_convert_i32_u
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I32)
        to = from.convert_u(to: :f32)
        raise EvalError, "failed to convert type" if !to.is_a?(F32)
        runtime.stack.push(to)


      when :f32_convert_i64_u
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I64)
        to = from.convert_u(to: :f32)
        raise EvalError, "failed to convert type" if !to.is_a?(F32)
        runtime.stack.push(to)


      when :f32_demote_f64
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F64)
        to = from.demote(to: :f32)
        raise EvalError, "failed to convert type" if !to.is_a?(F32)
        runtime.stack.push(to)


      when :f32_reinterpret_i32
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I32)
        to = from.reinterpret(to: :f32)
        raise EvalError, "failed to convert type" if !to.is_a?(F32)
        runtime.stack.push(to)


      when :f64_convert_i32_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I32)
        to = from.convert_s(to: :f64)
        raise EvalError, "failed to convert type" if !to.is_a?(F64)
        runtime.stack.push(to)


      when :f64_convert_i64_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I64)
        to = from.convert_s(to: :f64)
        raise EvalError, "failed to convert type" if !to.is_a?(F64)
        runtime.stack.push(to)


      when :f64_convert_i32_u
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I32)
        to = from.convert_u(to: :f64)
        raise EvalError, "failed to convert type" if !to.is_a?(F64)
        runtime.stack.push(to)


      when :f64_convert_i64_u
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I64)
        to = from.convert_u(to: :f64)
        raise EvalError, "failed to convert type" if !to.is_a?(F64)
        runtime.stack.push(to)


      when :f64_promote_f32
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(F32)
        to = from.promote(to: :f64)
        raise EvalError, "failed to convert type" if !to.is_a?(F64)
        runtime.stack.push(to)


      when :f64_reinterpret_i64
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(I64)
        to = from.reinterpret(to: :f64)
        raise EvalError, "failed to convert type" if !to.is_a?(F64)
        runtime.stack.push(to)


      else
        raise "Unknown opcode for namespace #{insn.namespace}: #{insn.code}"
      end
    end
  end
end
