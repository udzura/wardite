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
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    load8_s: <<~RUBY,
      when :${PREFIX}_load8_s
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    load8_u: <<~RUBY,
      when :${PREFIX}_load8_u
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    load16_s: <<~RUBY,
      when :${PREFIX}_load16_s
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    load16_u: <<~RUBY,
      when :${PREFIX}_load16_u
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    load32_s: <<~RUBY,
      when :${PREFIX}_load32_s
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    load32_u: <<~RUBY,
      when :${PREFIX}_load32_u
        raise "TODO! unsupported \#{insn.inspect}"
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
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    store16: <<~RUBY,
      when :${PREFIX}_store16
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    store32: <<~RUBY,
      when :${PREFIX}_store32
        raise "TODO! unsupported \#{insn.inspect}"
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
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    eq: <<~RUBY,
      when :${PREFIX}_eq
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    ne: <<~RUBY,
      when :${PREFIX}_ne
        raise "TODO! unsupported \#{insn.inspect}"
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
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    ctz: <<~RUBY,
      when :${PREFIX}_ctz
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    popcnt: <<~RUBY,
      when :${PREFIX}_popcnt
        raise "TODO! unsupported \#{insn.inspect}"
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
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    div_s: <<~RUBY,
      when :${PREFIX}_div_s
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    div_u: <<~RUBY,
      when :${PREFIX}_div_u
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    div: <<~RUBY,
      when :${PREFIX}_div
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    rem_s: <<~RUBY,
      when :${PREFIX}_rem_s
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    rem_u: <<~RUBY,
      when :${PREFIX}_rem_u
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    and: <<~RUBY,
      when :${PREFIX}_and
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    or: <<~RUBY,
      when :${PREFIX}_or
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    xor: <<~RUBY,
      when :${PREFIX}_xor
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    shl: <<~RUBY,
      when :${PREFIX}_shl
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    shr_s: <<~RUBY,
      when :${PREFIX}_shr_s
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    shr_u: <<~RUBY,
      when :${PREFIX}_shr_u
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    rotl: <<~RUBY,
      when :${PREFIX}_rotl
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    rotr: <<~RUBY,
      when :${PREFIX}_rotr
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    # instructions for float
    abs: <<~RUBY,
      when :${PREFIX}_abs
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    neg: <<~RUBY,
      when :${PREFIX}_neg
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    ceil: <<~RUBY,
      when :${PREFIX}_ceil
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    floor: <<~RUBY,
      when :${PREFIX}_floor
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    trunc: <<~RUBY,
      when :${PREFIX}_trunc
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    nearest: <<~RUBY,
      when :${PREFIX}_nearest
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    sqrt: <<~RUBY,
      when :${PREFIX}_sqrt
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    min: <<~RUBY,
      when :${PREFIX}_min
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    max: <<~RUBY,
      when :${PREFIX}_max
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    copysign: <<~RUBY,
      when :${PREFIX}_copysign
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    # ...end generative ops
  }
end