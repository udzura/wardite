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
    code = DEF.dup
    method = op.to_s
    symbol = "#{to.to_s}_#{method}_#{from.to_sym}"
    extra_kargs = ""
    
    if method == "extend"
      method = "extend_"
    elsif method =~ /^extendN_(u|s)$/
      suffix = $1
      from_size = from.to_s.scan(/\d+/).join
      symbol = "#{to.to_s}_extend_#{from_size}_#{suffix}"
      extra_kargs = ", from: :#{from.to_s}"
    elsif method.end_with?("_s") or method.end_with?("_u")
      core = method.sub(/_(s|u)$/, "")
      suffix = method.scan(/_(s|u)$/).join
      symbol = "#{to.to_s}_#{core}_#{from.to_sym}_#{suffix}"
    end
    # NOTE to is as namespace
    code.gsub!(/\$\{SYMBOL\}/, symbol)
    code.gsub!(/\$\{METHOD\}/, method)
    code.gsub!(/\$\{TO\}/, to.to_s)
    code.gsub!(/\$\{TO_CLASS\}/, to_class(to.to_sym))
    code.gsub!(/\$\{FROM_CLASS\}/, to_class(from.to_sym))
    code.gsub!(/\$\{EXTRA_KARGS\}/, extra_kargs)
    return code
  end

  def self.to_class(typ)
    {
      i8: "I32",
      i16: "I32",
      i32: "I32",
      i64: "I64",
      f32: "F32",
      f64: "F64",
    }[typ]
  end

  # ope_templates
  DEF = <<~RUBY
    when :${SYMBOL}
      from = runtime.stack.pop
      raise EvalError, "maybe empty or invalid stack" if !from.is_a?(${FROM_CLASS})
      to = from.${METHOD}(to: :${TO}${EXTRA_KARGS})
      raise EvalError, "failed to convert type" if !to.is_a?(${TO_CLASS})
      runtime.stack.push(to)
  RUBY
end
