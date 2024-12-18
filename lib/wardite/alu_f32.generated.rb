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
        _align = insn.operand[0] # TODO: alignment support?
        offset = insn.operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)
      
        addr = runtime.stack.pop
        if !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end
      
        at = addr.value + offset
        data_end = at + F32.new.memsize / 8
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        buf = memory.data[at...data_end]
        if !buf
          raise EvalError, "invalid memory range"
        end
        runtime.stack.push(F32.from_bytes(buf))


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
        target = runtime.stack.pop
        if !target.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = target.value.zero? ? 1 : 0
        runtime.stack.push(I32(value))


      when :f32_eq
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F32) || !left.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value == right.value) ? 1 : 0
        runtime.stack.push(I32(value))


      when :f32_ne
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F32) || !left.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value != right.value) ? 1 : 0
        runtime.stack.push(I32(value))


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
        x = runtime.stack.pop
        if !x.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(F32(x.value.abs))


      when :f32_neg
        x = runtime.stack.pop
        if !x.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(F32(-(x.value)))


      when :f32_ceil
        x = runtime.stack.pop
        if !x.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(F32(x.value.ceil.to_f))


      when :f32_floor
        x = runtime.stack.pop
        if !x.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(F32(x.value.floor.to_f))


      when :f32_trunc
        x = runtime.stack.pop
        if !x.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(F32(x.value.to_i.to_f))


      when :f32_nearest
        x = runtime.stack.pop
        if !x.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(F32(x.value.round.to_f))


      when :f32_sqrt
        x = runtime.stack.pop
        if !x.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(F32(x.value ** 0.5))


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
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F32) || !left.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(F32(left.value * right.value))


      when :f32_div
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F32) || !left.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(F32(left.value / right.value))


      when :f32_min
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F32) || !left.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        if right.value.nan? || left.value.nan?
          runtime.stack.push(F32(Float::NAN))
          return
        end
        runtime.stack.push(F32([left.value, right.value].min))


      when :f32_max
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F32) || !left.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        if right.value.nan? || left.value.nan?
          runtime.stack.push(F32(Float::NAN))
          return
        end
        runtime.stack.push(F32([left.value, right.value].max))


      when :f32_copysign
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(F32) || !left.is_a?(F32)
          raise EvalError, "maybe empty or invalid stack"
        end
        if left.sign == right.sign
          runtime.stack.push(F32(left.value))
        else
          runtime.stack.push(F32(-left.value))
        end


      else
        raise "Unknown opcode for namespace #{insn.namespace}: #{insn.code}"
      end
    end
  end
end
