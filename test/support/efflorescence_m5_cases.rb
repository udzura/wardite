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
      above_half = type == "f32" ? "0x1.000002p-1" : "0x1.0000000000001p-1"
      below_half = type == "f32" ? "0x1.fffffep-2" : "0x1.fffffffffffffp-2"
      cases += [["nearest", [above_half], "1"], ["nearest", [below_half], "0"]]
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

  def float_conversion_cases
    cases = %w[i32 i64].flat_map do |dest|
      width = Integer(dest.delete_prefix("i"))
      %w[f32 f64].flat_map do |source|
        precision = source == "f32" ? 24 : 53
        %w[s u].flat_map do |sign|
          upper_exponent = sign == "s" ? width - 1 : width
          limit = 1 << upper_exponent
          step = 1 << [upper_exponent - precision, 0].max
          minimum = sign == "s" ? -limit : 0
          inputs = [
            ["0", 0], ["-0", 0], ["-0.75", 0], ["1.75", 1],
            ["-1", sign == "s" ? -1 : "overflow"],
            ["inf", "overflow"], ["-inf", "overflow"], ["-nan:0x123", "invalid"],
            ["0x1p#{upper_exponent}", "overflow"],
            [(limit - step).to_s, limit - step]
          ]
          if sign == "s"
            inputs << [minimum.to_s, minimum]
            step_below_min = 1 << [upper_exponent + 1 - precision, 0].max
            inputs << [(minimum - step_below_min).to_s, "overflow"]
            inputs << ["-2147483648.75", minimum] if dest == "i32" && source == "f64"
          end
          [false, true].flat_map do |sat|
            op = "#{dest}.trunc#{sat ? '_sat' : ''}_#{source}_#{sign}"
            inputs.map do |literal, expected|
              if sat
                expected = case expected
                           when "invalid" then 0
                           when "overflow" then literal.start_with?("-") ? minimum : limit - 1
                           else expected
                           end
              end
              expected = integer_carrier(dest, expected) if expected.is_a?(Integer)
              [op, "#{source}.const #{literal}", dest, expected]
            end
          end
        end
      end
    end

    double_rounding = (1 << 62) + (1 << 38)
    %w[f32 f64].each do |dest|
      %w[i32 i64].each do |source|
        %w[s u].each do |sign|
          op = "#{dest}.convert_#{source}_#{sign}"
          width = Integer(source.delete_prefix("i"))
          boundary = sign == "s" ? -1 : (1 << width) - 1
          expected = sign == "s" ? "-1" : (dest == "f64" && width == 32 ? "4294967295" : "0x1p#{width}")
          cases.concat([
            [op, "#{source}.const 0", dest, "0"],
            [op, "#{source}.const #{boundary}", dest, expected],
          ])
          if dest == "f32" && source == "i64"
            cases.concat([
              [op, "i64.const #{double_rounding}", dest, "0x1p62"],
              [op, "i64.const #{double_rounding + 1}", dest, "0x1.000002p62"],
              [op, "i64.const #{double_rounding - 1}", dest, "0x1p62"],
              [op, "i64.const #{double_rounding + (1 << 39)}", dest, "0x1.000004p62"],
            ])
          end
          if dest == "f64" && source == "i64"
            exponent = sign == "s" ? 62 : 63
            half = 1 << (exponent - 53)
            cases << [op, "i64.const #{(1 << exponent) + half}", dest, "0x1p#{exponent}"]
            cases << [op, "i64.const #{(1 << exponent) + half + 1}", dest, "0x1.0000000000001p#{exponent}"]
          end
        end
      end
    end
    cases.concat([
      ["i32.reinterpret_f32", "f32.const -nan:0x123 f32.abs", "i32", 0x7f800123],
      ["i32.reinterpret_f32", "f32.const nan:0x123 f32.neg", "i32", 0xff800123],
      ["i32.reinterpret_f32", "f32.const nan:0x123 f32.const -0 f32.copysign", "i32", 0xff800123],
      ["i64.reinterpret_f64", "f64.const -nan:0x123 f64.abs", "i64", 0x7ff0000000000123],
      ["i64.reinterpret_f64", "f64.const nan:0x123 f64.neg", "i64", -0x000ffffffffffedd],
      ["i64.reinterpret_f64", "f64.const nan:0x123 f64.const -0 f64.copysign", "i64", -0x000ffffffffffedd],
      ["i32.reinterpret_f32", "f32.const 1 f32.const 0x1p-24 f32.add f32.const 1 f32.sub", "i32", 0],
      ["f32.convert_i64_s", "i64.const #{-double_rounding - 1}", "f32", "-0x1.000002p62"],
      ["f32.convert_i64_s", "i64.const -9223372036854775808", "f32", "-0x1p63"],
      ["f32.demote_f64", "f64.const 0x1.000001p0", "f32", "1"],
      ["f32.demote_f64", "f64.const 0x1.0000010000001p0", "f32", "0x1.000002p0"],
      ["f32.demote_f64", "f64.const 0x1.ffffffp127", "f32", "inf"],
      ["f32.demote_f64", "f64.const -0x1p-150", "f32", "-0"],
      ["f32.demote_f64", "f64.const -0x1.0000000000001p-150", "f32", "-0x1p-149"],
      ["f32.demote_f64", "f64.const -nan:0x123", "f32", "nan"],
      ["f64.promote_f32", "f32.const 0x1p-149", "f64", "0x1p-149"],
      ["f64.promote_f32", "f32.const 0x1.fffffep127", "f64", "0x1.fffffep127"],
      ["f64.promote_f32", "f32.const -0", "f64", "-0"],
      ["f64.promote_f32", "f32.const nan:0x123", "f64", "nan"],
      ["f32.reinterpret_i32", "i32.const 0x80000000", "f32", "-0"],
      ["f64.reinterpret_i64", "i64.const 0x8000000000000000", "f64", "-0"],
      ["i32.reinterpret_f32", "f32.const -nan:0x123", "i32", 0xff800123],
      ["i64.reinterpret_f64", "f64.const -nan:0x123", "i64", -0x000ffffffffffedd],
    ])
  end

  def integer_carrier(type, value)
    return value & 0xffffffff if type == "i32"
    ((value + (1 << 63)) % (1 << 64)) - (1 << 63)
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
