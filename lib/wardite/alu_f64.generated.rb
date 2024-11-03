# rbs_inline: enabled
require_relative "value"

module Wardite
  module Evaluator
    # @rbs runtime: Runtime
    # @rbs frame: Frame
    # @rbs insn: Op
    # @rbs return: void 
    def self.f64_eval_insn(runtime, frame, insn)
      case insn.code

      when :f64_load
        raise "TODO! unsupported #{insn.inspect}"


      when :f64_store
        _align = insn.operand[0] # TODO: alignment support?
        offset = insn.operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)
      
        value = runtime.stack.pop
        addr = runtime.stack.pop
        if !value.is_a?(F64) || !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end
      
        at = addr.value + offset
        data_end = at + value.packed.size
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        memory.data[at...data_end] = value.packed


      when :f64_const
        const = insn.operand[0]
        if !const.is_a?(Float)
          raise EvalError, "invalid type of operand"
        end
        runtime.stack.push(F64(const))


      when :f64_eqz
        target = runtime.stack.pop
        if !target.is_a?(F64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = target.value.zero? ? 1 : 0
        runtime.stack.push(I32(value))


      when :f64_eq
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F64) || !left.is_a?(F64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value == right.value) ? 1 : 0
        runtime.stack.push(I32(value))


      when :f64_ne
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F64) || !left.is_a?(F64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value != right.value) ? 1 : 0
        runtime.stack.push(I32(value))


      when :f64_lt
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F64) || !left.is_a?(F64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value < right.value) ? 1 : 0
        runtime.stack.push(I32(value))


      when :f64_gt
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F64) || !left.is_a?(F64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value > right.value) ? 1 : 0
        runtime.stack.push(I32(value))


      when :f64_le
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F64) || !left.is_a?(F64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value <= right.value) ? 1 : 0
        runtime.stack.push(I32(value))


      when :f64_ge
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F64) || !left.is_a?(F64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value >= right.value) ? 1 : 0
        runtime.stack.push(I32(value))


      when :f64_abs
        raise "TODO! unsupported #{insn.inspect}"


      when :f64_neg
        raise "TODO! unsupported #{insn.inspect}"


      when :f64_ceil
        raise "TODO! unsupported #{insn.inspect}"


      when :f64_floor
        raise "TODO! unsupported #{insn.inspect}"


      when :f64_trunc
        raise "TODO! unsupported #{insn.inspect}"


      when :f64_nearest
        raise "TODO! unsupported #{insn.inspect}"


      when :f64_sqrt
        raise "TODO! unsupported #{insn.inspect}"


      when :f64_add
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F64) || !left.is_a?(F64)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(F64(left.value + right.value))


      when :f64_sub
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F64) || !left.is_a?(F64)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(F64(left.value - right.value))


      when :f64_mul
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F64) || !left.is_a?(F64)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(F64(left.value * right.value))


      when :f64_div
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F64) || !left.is_a?(F64)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(F64(left.value / right.value))


      when :f64_min
        raise "TODO! unsupported #{insn.inspect}"


      when :f64_max
        raise "TODO! unsupported #{insn.inspect}"


      when :f64_copysign
        raise "TODO! unsupported #{insn.inspect}"


      else
        raise "Unknown opcode for namespace #{insn.namespace}: #{insn.code}"
      end
    end
  end
end
