# rbs_inline: enabled
require_relative "value"

module Wardite
  module Evaluator
    # @rbs runtime: Runtime
    # @rbs frame: Frame
    # @rbs insn: Op
    # @rbs return: void 
    def self.f32_eval_insn(runtime, frame, insn)
      case insn.code

      when :f32_load
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_store
        _align = insn.operand[0] # TODO: alignment support?
        offset = insn.operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)
      
        value = runtime.stack.pop
        addr = runtime.stack.pop
        if !value.is_a?(F32) || !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end
      
        at = addr.value + offset
        data_end = at + value.packed.size
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        memory.data[at...data_end] = value.packed


      when :f32_const
        const = insn.operand[0]
        if !const.is_a?(Float)
          raise EvalError, "invalid type of operand"
        end
        runtime.stack.push(F32(const))


      when :f32_eqz
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_eq
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_ne
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_lt
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F32) || !left.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value < right.value) ? 1 : 0
        runtime.stack.push(I32(value))


      when :f32_gt
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F32) || !left.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value > right.value) ? 1 : 0
        runtime.stack.push(I32(value))


      when :f32_le
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F32) || !left.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value <= right.value) ? 1 : 0
        runtime.stack.push(I32(value))


      when :f32_ge
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F32) || !left.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value >= right.value) ? 1 : 0
        runtime.stack.push(I32(value))


      when :f32_abs
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_neg
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_ceil
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_floor
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_trunc
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_nearest
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_sqrt
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_add
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F32) || !left.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(F32(left.value + right.value))


      when :f32_sub
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F32) || !left.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(F32(left.value - right.value))


      when :f32_mul
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_div
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_min
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_max
        raise "TODO! unsupported #{insn.inspect}"


      when :f32_copysign
        raise "TODO! unsupported #{insn.inspect}"


      else
        raise "Unknown opcode for namespace #{insn.namespace}: #{insn.code}"
      end
    end
  end
end
