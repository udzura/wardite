require "stringio"

module GenAlu
  def self.execute(path, prefix: "i32", defined_ops: [])
    parent_dir = File.dirname(path)
    system "mkdir -p #{parent_dir}"

    basic_module = File.read(
      File.expand_path("../templates/alu_module.rb.tmpl", __FILE__)
    )
    basic_module.gsub!(/\$\{PREFIX\}/, prefix)
    ope_defs = generate_ops(prefix: prefix, defined_ops: defined_ops)
    basic_module.gsub!(/\$\{DEFS\}/, ope_defs)

    dest = File.open(path, "w")
    dest.puts basic_module

    $stderr.puts "generated: #{path}"
  end

  def self.generate_ops(prefix:, defined_ops:)
    result = StringIO.new("")
    defined_ops.each do |op|
      code = DEFS[op.to_sym].dup
      if ! code
        raise "unsupported code specified! #{op.inspect}"
      end
      code.gsub!(/\$\{PREFIX\}/, prefix)
      code.gsub!(/\$\{CLASS\}/, to_class(prefix.to_sym))
      result << "\n"
      code.each_line do |ln|
        result << " " * 6 << ln
      end
      result << "\n"
    end
    result.string
  end

  def self.to_class(prefix)
    {
      i32: "I32",
      i64: "I64",
      f32: "F32",
      f64: "F64",
    }[prefix]
  end
 
  # ope_templates
  DEFS = { #: Hash[Symbol, String]
    load: <<~RUBY,
      when :${PREFIX}_load
        _align = insn.operand[0] # TODO: alignment support?
        offset = insn.operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)

        addr = runtime.stack.pop
        if !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end

        at = addr.value + offset
        data_end = at + ${CLASS}.new.memsize / 8
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        buf = memory.data[at...data_end]
        if !buf
          raise EvalError, "invalid memory range"
        end
        runtime.stack.push(${CLASS}.from_bytes(buf))
    RUBY

    load8_s: <<~RUBY,
      when :${PREFIX}_load8_s
        _align = insn.operand[0] # TODO: alignment support?
        offset = insn.operand[1]
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
        runtime.stack.push(${CLASS}.from_bytes(buf, size: 8, signed: true))
    RUBY

    load8_u: <<~RUBY,
      when :${PREFIX}_load8_u
        _align = insn.operand[0] # TODO: alignment support?
        offset = insn.operand[1]
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
        runtime.stack.push(${CLASS}.from_bytes(buf, size: 8, signed: false))
    RUBY

    load16_s: <<~RUBY,
      when :${PREFIX}_load16_s
        _align = insn.operand[0] # TODO: alignment support?
        offset = insn.operand[1]
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
        runtime.stack.push(${CLASS}.from_bytes(buf, size: 16, signed: true))
    RUBY

    load16_u: <<~RUBY,
      when :${PREFIX}_load16_u
        _align = insn.operand[0] # TODO: alignment support?
        offset = insn.operand[1]
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
        runtime.stack.push(${CLASS}.from_bytes(buf, size: 16, signed: false))
    RUBY

    load32_s: <<~RUBY,
      when :${PREFIX}_load32_s
        _align = insn.operand[0] # TODO: alignment support?
        offset = insn.operand[1]
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
        runtime.stack.push(${CLASS}.from_bytes(buf, size: 32, signed: true))
    RUBY

    load32_u: <<~RUBY,
      when :${PREFIX}_load32_u
        _align = insn.operand[0] # TODO: alignment support?
        offset = insn.operand[1]
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
        runtime.stack.push(${CLASS}.from_bytes(buf, size: 32, signed: false))
    RUBY

    store: <<~RUBY,
      when :${PREFIX}_store
        _align = insn.operand[0] # TODO: alignment support?
        offset = insn.operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)

        value = runtime.stack.pop
        addr = runtime.stack.pop
        if !value.is_a?(${CLASS}) || !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end

        at = addr.value + offset
        data_end = at + value.packed.size
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        memory.data[at...data_end] = value.packed
    RUBY

    store8: <<~RUBY,
      when :${PREFIX}_store8
        _align = insn.operand[0] # TODO: alignment support?
        offset = insn.operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)

        value = runtime.stack.pop
        addr = runtime.stack.pop
        if !value.is_a?(${CLASS}) || !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end

        at = addr.value + offset
        data_end = at + 1
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        memory.data[at...data_end] = value.packed(size: 8)
    RUBY

    store16: <<~RUBY,
      when :${PREFIX}_store16
        _align = insn.operand[0] # TODO: alignment support?
        offset = insn.operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)

        value = runtime.stack.pop
        addr = runtime.stack.pop
        if !value.is_a?(${CLASS}) || !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end

        at = addr.value + offset
        data_end = at + 2
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        memory.data[at...data_end] = value.packed(size: 16)
    RUBY

    store32: <<~RUBY,
      when :${PREFIX}_store32
        _align = insn.operand[0] # TODO: alignment support?
        offset = insn.operand[1]
        raise EvalError, "[BUG] invalid type of operand" if !offset.is_a?(Integer)

        value = runtime.stack.pop
        addr = runtime.stack.pop
        if !value.is_a?(${CLASS}) || !addr.is_a?(I32)
          raise EvalError, "maybe stack too short"
        end

        at = addr.value + offset
        data_end = at + 4
        memory = runtime.instance.store.memories[0] || raise("[BUG] no memory")
        memory.data[at...data_end] = value.packed(size: 32)
    RUBY

    const: <<~RUBY,
      when :${PREFIX}_const
        const = insn.operand[0]
        if !const.is_a?(Integer)
          raise EvalError, "invalid type of operand"
        end
        runtime.stack.push(${CLASS}(const))
    RUBY

    const__f: <<~RUBY,
      when :${PREFIX}_const
        const = insn.operand[0]
        if !const.is_a?(Float)
          raise EvalError, "invalid type of operand"
        end
        runtime.stack.push(${CLASS}(const))
    RUBY

    eqz: <<~RUBY,
      when :${PREFIX}_eqz
        target = runtime.stack.pop
        if !target.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = target.value.zero? ? 1 : 0
        runtime.stack.push(I32(value))
    RUBY

    eq: <<~RUBY,
      when :${PREFIX}_eq
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value == right.value) ? 1 : 0
        runtime.stack.push(I32(value))
    RUBY

    ne: <<~RUBY,
      when :${PREFIX}_ne
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value != right.value) ? 1 : 0
        runtime.stack.push(I32(value))
    RUBY

    lts: <<~RUBY,
      when :${PREFIX}_lts
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value_s < right.value_s) ? 1 : 0
        runtime.stack.push(I32(value))
    RUBY

    ltu: <<~RUBY,
      when :${PREFIX}_ltu
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value < right.value) ? 1 : 0
        runtime.stack.push(I32(value))
    RUBY

    lt: <<~RUBY,
      when :${PREFIX}_lt
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value < right.value) ? 1 : 0
        runtime.stack.push(I32(value))
    RUBY

    gts: <<~RUBY,
      when :${PREFIX}_gts
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value_s > right.value_s) ? 1 : 0
        runtime.stack.push(I32(value))
    RUBY

    gtu: <<~RUBY,
      when :${PREFIX}_gtu
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value > right.value) ? 1 : 0
        runtime.stack.push(I32(value))
    RUBY

    gt: <<~RUBY,
      when :${PREFIX}_gt
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value > right.value) ? 1 : 0
        runtime.stack.push(I32(value))
    RUBY

    les: <<~RUBY,
      when :${PREFIX}_les
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value_s <= right.value_s) ? 1 : 0
        runtime.stack.push(I32(value))
    RUBY

    leu: <<~RUBY,
      when :${PREFIX}_leu
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value <= right.value) ? 1 : 0
        runtime.stack.push(I32(value))
    RUBY

    le: <<~RUBY,
      when :${PREFIX}_le
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value <= right.value) ? 1 : 0
        runtime.stack.push(I32(value))
    RUBY

    ges: <<~RUBY,
      when :${PREFIX}_ges
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value_s >= right.value_s) ? 1 : 0
        runtime.stack.push(I32(value))
    RUBY

    geu: <<~RUBY,
      when :${PREFIX}_geu
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value >= right.value) ? 1 : 0
        runtime.stack.push(I32(value))
    RUBY

    ge: <<~RUBY,
      when :${PREFIX}_ge
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value >= right.value) ? 1 : 0
        runtime.stack.push(I32(value))
    RUBY

    clz: <<~RUBY,
      when :${PREFIX}_clz
        target = runtime.stack.pop
        if !target.is_a?(${CLASS})
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
        runtime.stack.push(${CLASS}(count))
    RUBY

    ctz: <<~RUBY,
      when :${PREFIX}_ctz
        target = runtime.stack.pop
        if !target.is_a?(${CLASS})
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
        runtime.stack.push(${CLASS}(count))
    RUBY

    popcnt: <<~RUBY,
      when :${PREFIX}_popcnt
        target = runtime.stack.pop
        if !target.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        digits = target.memsize
        count = 0
        digits.times do |i|
          if (target.value & (1 << i)).zero?
            count += 1
          end
        end
        runtime.stack.push(${CLASS}(count))
    RUBY

    add: <<~RUBY,
      when :${PREFIX}_add
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(left.value + right.value))
    RUBY

    sub: <<~RUBY,
      when :${PREFIX}_sub
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(left.value - right.value))
    RUBY

    mul: <<~RUBY,
      when :${PREFIX}_mul
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(left.value * right.value))
    RUBY

    div_s: <<~RUBY,
      when :${PREFIX}_div_s
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(left.value_s / right.value_s))
    RUBY

    div_u: <<~RUBY,
      when :${PREFIX}_div_u
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(left.value / right.value))
    RUBY

    div: <<~RUBY,
      when :${PREFIX}_div
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(left.value / right.value))
    RUBY

    rem_s: <<~RUBY,
      when :${PREFIX}_rem_s
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(left.value_s % right.value_s))
    RUBY

    rem_u: <<~RUBY,
      when :${PREFIX}_rem_u
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(left.value % right.value))
    RUBY

    and: <<~RUBY,
      when :${PREFIX}_and
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(left.value & right.value))
    RUBY

    or: <<~RUBY,
      when :${PREFIX}_or
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(left.value | right.value))
    RUBY

    xor: <<~RUBY,
      when :${PREFIX}_xor
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(left.value ^ right.value))
    RUBY

    shl: <<~RUBY,
      when :${PREFIX}_shl
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = left.value << (right.value % right.memsize)
        value %= 1 << right.memsize

        runtime.stack.push(${CLASS}(value))
    RUBY

    shr_s: <<~RUBY,
      when :${PREFIX}_shr_s
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = left.value_s >> right.value
        runtime.stack.push(${CLASS}(value))
    RUBY

    shr_u: <<~RUBY,
      when :${PREFIX}_shr_u
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = left.value >> right.value
        runtime.stack.push(${CLASS}(value))
    RUBY

    rotl: <<~RUBY,
      when :${PREFIX}_rotl
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        rotated = left.value << right.value
        rest = left.value & (${CLASS}::${CLASS}_MAX << (right.memsize - right.value))
        value = rotated | (rest >> (right.memsize - right.value))
        runtime.stack.push(${CLASS}(value))
    RUBY

    rotr: <<~RUBY,
      when :${PREFIX}_rotr
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        rotated = left.value >> right.value
        rest = left.value & (${CLASS}::${CLASS}_MAX >> (right.memsize - right.value))
        value = rotated | (rest << (right.memsize - right.value))
        runtime.stack.push(${CLASS}(value))
    RUBY

    # instructions for float
    abs: <<~RUBY,
      when :${PREFIX}_abs
        x = runtime.stack.pop
        if !x.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(x.value.abs))
    RUBY

    neg: <<~RUBY,
      when :${PREFIX}_neg
        x = runtime.stack.pop
        if !x.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(-(x.value)))
    RUBY

    ceil: <<~RUBY,
      when :${PREFIX}_ceil
        x = runtime.stack.pop
        if !x.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(x.value.ceil.to_f))
    RUBY

    floor: <<~RUBY,
      when :${PREFIX}_floor
        x = runtime.stack.pop
        if !x.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(x.value.floor.to_f))
    RUBY

    trunc: <<~RUBY,
      when :${PREFIX}_trunc
        x = runtime.stack.pop
        if !x.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(x.value.to_i.to_f))
    RUBY

    nearest: <<~RUBY,
      when :${PREFIX}_nearest
        x = runtime.stack.pop
        if !x.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(x.value.round.to_f))
    RUBY

    sqrt: <<~RUBY,
      when :${PREFIX}_sqrt
        x = runtime.stack.pop
        if !x.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        runtime.stack.push(${CLASS}(x.value ** 0.5))
    RUBY

    min: <<~RUBY,
      when :${PREFIX}_min
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        if right.value.nan? || left.value.nan?
          runtime.stack.push(${CLASS}(Float::NAN))
          return
        end
        runtime.stack.push(${CLASS}([left.value, right.value].min))
    RUBY

    max: <<~RUBY,
      when :${PREFIX}_max
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        if right.value.nan? || left.value.nan?
          runtime.stack.push(${CLASS}(Float::NAN))
          return
        end
        runtime.stack.push(${CLASS}([left.value, right.value].max))
    RUBY

    copysign: <<~RUBY,
      when :${PREFIX}_copysign
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        if left.sign == right.sign
          runtime.stack.push(${CLASS}(left.value))
        else
          runtime.stack.push(${CLASS}(-left.value))
        end
    RUBY

    # ...end generative ops
  }
end