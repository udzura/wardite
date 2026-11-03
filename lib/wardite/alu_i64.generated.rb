# rbs_inline: enabled
require_relative "value"

module Wardite
  module Evaluator
    # @rbs runtime: Runtime
    # @rbs frame: Frame
    # @rbs code: Symbol
    # @rbs operand: Array[operandItem]
    # @rbs return: bool?
    def self.i64_eval_insn(runtime, frame, code, operand)
      case code

      when :i64_load
        _align = operand[0] # TODO: alignment support?
        offset = operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)
      
        addr = runtime.stack.pop
        if !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end
      
        at = addr.value + offset
        data_end = at + I64.new.memsize / 8
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        buf = memory.data[at...data_end]
        if !buf
          raise EvalError, "invalid memory range"
        end
        runtime.stack.push(I64.from_bytes(buf))


      when :i64_load8_s
        _align = operand[0] # TODO: alignment support?
        offset = operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)
      
        addr = runtime.stack.pop
        if !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end
      
        at = addr.value + offset
        data_end = at + 1
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        buf = memory.data[at...data_end]
        if !buf
          raise EvalError, "invalid memory range"
        end
        runtime.stack.push(I64.from_bytes(buf, size: 8, signed: true))


      when :i64_load8_u
        _align = operand[0] # TODO: alignment support?
        offset = operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)
      
        addr = runtime.stack.pop
        if !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end
      
        at = addr.value + offset
        data_end = at + 1
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        buf = memory.data[at...data_end]
        if !buf
          raise EvalError, "invalid memory range"
        end
        runtime.stack.push(I64.from_bytes(buf, size: 8, signed: false))


      when :i64_load16_s
        _align = operand[0] # TODO: alignment support?
        offset = operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)
      
        addr = runtime.stack.pop
        if !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end
      
        at = addr.value + offset
        data_end = at + 2
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        buf = memory.data[at...data_end]
        if !buf
          raise EvalError, "invalid memory range"
        end
        runtime.stack.push(I64.from_bytes(buf, size: 16, signed: true))


      when :i64_load16_u
        _align = operand[0] # TODO: alignment support?
        offset = operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)
      
        addr = runtime.stack.pop
        if !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end
      
        at = addr.value + offset
        data_end = at + 2
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        buf = memory.data[at...data_end]
        if !buf
          raise EvalError, "invalid memory range"
        end
        runtime.stack.push(I64.from_bytes(buf, size: 16, signed: false))


      when :i64_load32_s
        _align = operand[0] # TODO: alignment support?
        offset = operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)
      
        addr = runtime.stack.pop
        if !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end
      
        at = addr.value + offset
        data_end = at + 4
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        buf = memory.data[at...data_end]
        if !buf
          raise EvalError, "invalid memory range"
        end
        runtime.stack.push(I64.from_bytes(buf, size: 32, signed: true))


      when :i64_load32_u
        _align = operand[0] # TODO: alignment support?
        offset = operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)
      
        addr = runtime.stack.pop
        if !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end
      
        at = addr.value + offset
        data_end = at + 4
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        buf = memory.data[at...data_end]
        if !buf
          raise EvalError, "invalid memory range"
        end
        runtime.stack.push(I64.from_bytes(buf, size: 32, signed: false))


      when :i64_store
        _align = operand[0] # TODO: alignment support?
        offset = operand[1]
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
        _align = operand[0] # TODO: alignment support?
        offset = operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)
      
        value = runtime.stack.pop
        addr = runtime.stack.pop
        if !value.is_a?(I64) || !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end
      
        at = addr.value + offset
        data_end = at + 1
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        memory.data[at...data_end] = value.packed(size: 8)


      when :i64_store16
        _align = operand[0] # TODO: alignment support?
        offset = operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)
      
        value = runtime.stack.pop
        addr = runtime.stack.pop
        if !value.is_a?(I64) || !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end
      
        at = addr.value + offset
        data_end = at + 2
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        memory.data[at...data_end] = value.packed(size: 16)


      when :i64_store32
        _align = operand[0] # TODO: alignment support?
        offset = operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)
      
        value = runtime.stack.pop
        addr = runtime.stack.pop
        if !value.is_a?(I64) || !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end
      
        at = addr.value + offset
        data_end = at + 4
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        memory.data[at...data_end] = value.packed(size: 32)


      when :i64_const
        const = operand[0]
        if !const.is_a?(Integer)
          raise EvalError, "invalid type of operand"
        end
        runtime.stack.push(I64(const))


      when :i64_eqz
        target = runtime.stack.pop
        if !target.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = target.value.zero? ? 1 : 0
        runtime.stack.push(I32(value))


      when :i64_eq
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value == right.value) ? 1 : 0
        runtime.stack.push(I32(value))


      when :i64_ne
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value != right.value) ? 1 : 0
        runtime.stack.push(I32(value))


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
        target = runtime.stack.pop
        if !target.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        start = target.memsize - 1
        count = 0
        while start > -1
          if (target.value >> start).zero?
            count += 1
            start -= 1
          else
            break
          end
        end
        runtime.stack.push(I64(count))


      when :i64_ctz
        target = runtime.stack.pop
        if !target.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        finish = target.memsize
        count = 0
        while count < finish
          if (target.value & (1 << count)).zero?
            count += 1
          else
            break
          end
        end
        runtime.stack.push(I64(count))


      when :i64_popcnt
        target = runtime.stack.pop
        if !target.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        digits = target.memsize
        count = 0
        digits.times do |i|
          if (target.value & (1 << i)).nonzero?
            count += 1
          end
        end
        runtime.stack.push(I64(count))


      when :i64_add
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(left.add(right))


      when :i64_sub
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(I64(left.value - right.value))


      when :i64_mul
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(left.multiply(right))


      when :i64_div_s
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        dividend = left.value_s
        divisor = right.value_s
        signed_min = -(1 << (left.memsize - 2)) * 2
        if dividend == signed_min && divisor == -1
          raise IntegerOverflow, "integer overflow"
        end
        iresult = dividend / divisor
        # Ruby rounds integer division down; Wasm truncates toward zero.
        if (dividend < 0) != (divisor < 0) && dividend % divisor != 0
          iresult += 1
        end
        runtime.stack.push(I64(iresult))


      when :i64_div_u
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(I64(left.value / right.value))


      when :i64_rem_s
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        result = left.value_s % right.value_s
        if result > 0 && left.value_s < 0
          result = result - right.value_s
        elsif result < 0 && left.value_s > 0
          result = result - right.value_s
        end
        runtime.stack.push(I64(result))


      when :i64_rem_u
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(I64(left.value % right.value))


      when :i64_and
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(I64(left.value & right.value))


      when :i64_or
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(I64(left.value | right.value))


      when :i64_xor
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(I64(left.value ^ right.value))


      when :i64_shl
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(left.shift_left(right.value % 64))


      when :i64_shr_s
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = left.value_s >> (right.value % right.memsize)
        runtime.stack.push(I64(value))


      when :i64_shr_u
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        value = left.value >> (right.value % right.memsize)
        runtime.stack.push(I64(value))


      when :i64_rotl
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        k = right.value % 64
        value = left.shift_left(k).value | (left.value >> (64 - k))
        runtime.stack.push(I64(value))


      when :i64_rotr
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(I64) || !left.is_a?(I64)
          raise EvalError, "maybe empty or invalid stack"
        end
        k = right.value % 64
        value = (left.value >> k) | left.shift_left((64 - k) % 64).value
        runtime.stack.push(I64(value))


      else
        return
      end
      return true
    end
  end
end
