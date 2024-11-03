# rbs_inline: enabled
require_relative "value"

module Wardite
  module Evaluator
    # @rbs runtime: Runtime
    # @rbs frame: Frame
    # @rbs insn: Op
    # @rbs return: void 
    def self.i64_eval_insn(runtime, frame, insn)
      case insn.code

      when :i64_load
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_load8_s
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_load8_u
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_load16_s
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_load16_u
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_load32_s
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_load32_u
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_store
        _align = insn.operand[0] # TODO: alignment support?
        offset = insn.operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)
      
        value = runtime.stack.pop
        addr = runtime.stack.pop
        if !value.is_a?(I64) || !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end
      
        at = addr.value + offset
        data_end = at + value.packed.size
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        memory.data[at...data_end] = value.packed


      when :i64_store8
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_store16
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_store32
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_const
        const = insn.operand[0]
        if !const.is_a?(Integer)
          raise EvalError, "invalid type of operand"
        end
        runtime.stack.push(I64(const))


      when :i64_eqz
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_eq
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_ne
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_lts
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value_s < right.value_s) ? 1 : 0
        runtime.stack.push(I32(value))


      when :i64_ltu
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value < right.value) ? 1 : 0
        runtime.stack.push(I32(value))


      when :i64_gts
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value_s > right.value_s) ? 1 : 0
        runtime.stack.push(I32(value))


      when :i64_gtu
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value > right.value) ? 1 : 0
        runtime.stack.push(I32(value))


      when :i64_les
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value_s <= right.value_s) ? 1 : 0
        runtime.stack.push(I32(value))


      when :i64_leu
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value <= right.value) ? 1 : 0
        runtime.stack.push(I32(value))


      when :i64_ges
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value_s >= right.value_s) ? 1 : 0
        runtime.stack.push(I32(value))


      when :i64_geu
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value >= right.value) ? 1 : 0
        runtime.stack.push(I32(value))


      when :i64_clz
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_ctz
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_popcnt
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_add
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(I64(left.value + right.value))


      when :i64_sub
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(I64(left.value - right.value))


      when :i64_mul
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_div_s
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_div_u
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_rem_s
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_rem_u
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_and
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_or
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_xor
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_shl
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_shr_s
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_shr_u
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_rotl
        raise "TODO! unsupported #{insn.inspect}"


      when :i64_rotr
        raise "TODO! unsupported #{insn.inspect}"


      else
        raise "Unknown opcode for namespace #{insn.namespace}: #{insn.code}"
      end
    end
  end
end
