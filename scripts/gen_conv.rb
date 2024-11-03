require "stringio"

module GenConv
  def self.execute(path, defined_ops: {})
    parent_dir = File.dirname(path)
    system "mkdir -p #{parent_dir}"

    basic_module = File.read(
      File.expand_path("../templates/conv_module.rb.tmpl", __FILE__)
    )

    ope_defs = generate_ops(defined_ops: defined_ops)
    basic_module.gsub!(/\$\{DEFS\}/, ope_defs)

    dest = File.open(path, "w")
    dest.puts basic_module

    $stderr.puts "generated: #{path}"
  end

  def self.generate_ops(defined_ops:)
    result = StringIO.new("")
    defined_ops.each_pair do |to, ops|
      ops.each_pair do |op, argtypes|
        argtypes.each do |from|
          code = generate_one_branch(op: op, to: to, from: from)
          result << "\n"
          code.each_line do |ln|
            result << " " * 6 << ln
          end
          result << "\n"
        end
      end      
    end
    result.string
  end

  def self.generate_one_branch(op:, to:, from:)
    code = DEFS[op.to_sym].dup
    if ! code
      raise "unsupported code specified! #{op.inspect}"
    end
    # NOTE to is as namespace
    code.gsub!(/\$\{TO\}/, to.to_s)
    code.gsub!(/\$\{TO_CLASS\}/, to_class(to.to_sym))
    code.gsub!(/\$\{FROM\}/, from.to_s)
    code.gsub!(/\$\{FROM_CLASS\}/, to_class(from.to_sym))
    return code
  end

  def self.to_class(prefix)
    {
      i32: "I32",
      i64: "I64",
      i32_s: "I32",
      i64_s: "I64",
      i32_u: "I32",
      i64_u: "I64",
      f32: "F32",
      f64: "F64",
      f32_s: "F32",
      f64_s: "F64",
      f32_u: "F32",
      f64_u: "F64",
    }[prefix]
  end

  # ope_templates
  DEFS = { #: Hash[Symbol, String]
    wrap: <<~RUBY,
      when :${TO}_wrap_${FROM}
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    trunc__s: <<~RUBY,
      when :${TO}_trunc_${FROM}_s
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(${FROM_CLASS})
        to = from.trunc_s(to: :${TO})
        raise EvalError, "failed to convert type" if !to.is_a?(${TO_CLASS})
        runtime.stack.push(to)
    RUBY

    trunc__u: <<~RUBY,
      when :${TO}_trunc_${FROM}_u
        from = runtime.stack.pop
        raise EvalError, "maybe empty or invalid stack" if !from.is_a?(${FROM_CLASS})
        to = from.trunc_u(to: :${TO})
        raise EvalError, "failed to convert type" if !to.is_a?(${TO_CLASS})
        runtime.stack.push(to)
    RUBY

    extend: <<~RUBY,
      when :${TO}_extend_${FROM}
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    convert: <<~RUBY,
      when :${TO}_convert_${FROM}
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    demote: <<~RUBY,
      when :${TO}_demote_${FROM}
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    promote: <<~RUBY,
      when :${TO}_promote_${FROM}
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY

    reinterpret: <<~RUBY,
      when :${TO}_reinterpret_${FROM}
        raise "TODO! unsupported \#{insn.inspect}"
    RUBY
  }
end
