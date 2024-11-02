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
      code = DEFS[op.to_sym]
      if ! code
        raise "unsupported code specified!"
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
    lts: <<~RUBY,
      when :${PREFIX}_lts
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value < right.value) ? 1 : 0
        runtime.stack.push(I32(value))
    RUBY

    leu: <<~RUBY,
      when :${PREFIX}_leu
        right, left = runtime.stack.pop, runtime.stack.pop
        if !right.is_a?(${CLASS}) || !left.is_a?(${CLASS})
          raise EvalError, "maybe empty or invalid stack"
        end
        value = (left.value >= right.value) ? 1 : 0
        runtime.stack.push(I32(value))
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
  }
end