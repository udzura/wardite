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
        raise "TODO! unsupported #{insn.inspect}"


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
        raise "TODO! unsupported #{insn.inspect}"


      when :i32_trunc_f64_u
        raise "TODO! unsupported #{insn.inspect}"


      when :i32_reinterpret_f32
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_extend_i32_s
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_extend_i32_u
        raise "TODO! unsupported #{insn.inspect}"


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
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_trunc_f64_u
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_reinterpret_f64
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_convert_i32_s
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_convert_i32_u
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_convert_i64_s
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_convert_i64_u
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_demote_f64
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_reinterpret_i32
        raise "TODO! unsupported #{insn.inspect}"


      when :f64_convert_i32_s
        raise "TODO! unsupported #{insn.inspect}"


      when :f64_convert_i32_u
        raise "TODO! unsupported #{insn.inspect}"


      when :f64_convert_i64_s
        raise "TODO! unsupported #{insn.inspect}"


      when :f64_convert_i64_u
        raise "TODO! unsupported #{insn.inspect}"


      when :f64_promote_f32
        raise "TODO! unsupported #{insn.inspect}"


      when :f64_reinterpret_i64
        raise "TODO! unsupported #{insn.inspect}"


      else
        raise "Unknown opcode for namespace #{insn.namespace}: #{insn.code}"
      end
    end
  end
end
