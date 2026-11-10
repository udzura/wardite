# frozen_string_literal: true

module EfflorescenceM5Cases
  FLOAT_COMPARE = %w[eq ne lt gt le ge].freeze
  FLOAT_UNARY = %w[abs neg ceil floor trunc nearest sqrt].freeze
  FLOAT_BINARY = %w[add sub mul div min max copysign].freeze

  def float_alu_cases
    %w[f32 f64].flat_map do |type|
      cases = FLOAT_COMPARE.flat_map do |op|
        equal = %w[eq le ge].include?(op) ? 1 : 0
        ordered = %w[ne lt le].include?(op) ? 1 : 0
        [[op, %w[-0 0], equal], [op, %w[1 2], ordered], [op, %w[-nan:0x123 1], op == "ne" ? 1 : 0]]
      end
      cases += [
        ["abs", %w[-0], "0"], ["neg", %w[0], "-0"],
        ["copysign", %w[0 -nan:0x123], "-0"], ["copysign", %w[-1 0], "1"],
        ["ceil", %w[-0.75], "-0"], ["ceil", %w[0.75], "1"],
        ["floor", %w[-0.75], "-1"], ["floor", %w[0.75], "0"],
        ["trunc", %w[-0.75], "-0"], ["trunc", %w[-2.75], "-2"],
        ["sqrt", %w[-0], "-0"], ["sqrt", %w[-1], "nan"], ["sqrt", %w[4], "2"],
        ["add", %w[1 2], "3"], ["add", %w[inf -inf], "nan"],
        ["sub", %w[1 2], "-1"], ["sub", %w[inf inf], "nan"],
        ["mul", %w[-1 2], "-2"], ["mul", %w[-0 inf], "nan"],
        ["div", %w[0 0], "nan"], ["div", %w[2 -0], "-inf"], ["div", %w[inf inf], "nan"],
        ["min", %w[1 2], "1"], ["min", %w[0 -0], "-0"], ["min", %w[nan 1], "nan"],
        ["max", %w[1 2], "2"], ["max", %w[-0 0], "0"], ["max", %w[1 nan], "nan"],
      ]
      cases += %w[ceil floor trunc nearest].flat_map do |op|
        %w[-0 inf -inf nan].map { |value| [op, [value], value] }
      end
      cases += {
        "0.49999999999999994" => "0", "0.5" => "0", "-0.5" => "-0",
        "1.5" => "2", "-1.5" => "-2", "2.5" => "2", "-2.5" => "-2"
      }.map { |value, expected| ["nearest", [value], expected] }
      cases += if type == "f32"
                 [
                   ["add", %w[1 0x1p-24], "1"],
                   ["add", %w[0x1.000002p0 0x1p-24], "0x1.000004p0"],
                   ["sqrt", %w[0x1.000002p0], "1"],
                   ["sqrt", %w[0x1.000004p0], "0x1.000002p0"],
                   ["div", %w[0x1.000002p-126 2], "0x1p-127"],
                   ["div", %w[0x1.000006p-126 2], "0x1.000008p-127"],
                   ["div", %w[0x1p-149 2], "0"],
                   ["div", %w[0x1p-149 0x1.fffffep0], "0x1p-149"],
                   ["mul", %w[0x1p-149 2], "0x1p-148"],
                 ]
               else
                 [
                   ["add", %w[1 0x1p-53], "1"],
                   ["add", %w[0x1.0000000000001p0 0x1p-53], "0x1.0000000000002p0"],
                   ["sqrt", %w[2], "0x1.6a09e667f3bcdp0"],
                   ["div", %w[0x1.8p-1073 2], "0x1p-1073"],
                   ["mul", %w[0x1p-1074 2], "0x1p-1073"],
                 ]
               end
      cases.map do |op, operands, expected|
        result_type = expected.is_a?(Integer) ? "i32" : type
        [type + "." + op, operands.map { |operand| "#{type}.const #{operand}" }.join(" "),
         result_type, expected]
      end
    end
  end

  def float_vectors(cases)
    functions, rows = cases.each_with_index.map do |(op, operands, type, expected), index|
      name = "case#{index}"
      wasm = "(func (export \"#{name}\") (result #{type}) #{operands} #{op})"
      bits = case expected
             when Integer then expected
             when "nan", "overflow", "invalid" then expected
             else
               value = { "inf" => Float::INFINITY, "-inf" => -Float::INFINITY }.fetch(expected) { Float(expected) }
               type == "f32" ? [value].pack("e").unpack1("V") : [value].pack("E").unpack1("q<")
             end
      [wasm, [name, type, op.tr(".", "_").upcase, bits].join(" ")]
    end.transpose
    ["(module #{functions.join("\n")})", rows.join("\n") + "\n"]
  end
end
