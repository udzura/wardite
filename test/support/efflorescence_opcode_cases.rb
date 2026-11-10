# frozen_string_literal: true

require_relative "efflorescence_manifest"
require_relative "efflorescence_parity"
require_relative "efflorescence_m5_cases"

module EfflorescenceOpcodeCases
  extend self
  include EfflorescenceM5Cases
  Observation = EfflorescenceParity::Observation
  Fixture = EfflorescenceParity::Fixture
  PAGE = 65536
  ROUTES = EfflorescenceManifest.rows.to_h { |row| [row["wasm"], row] }.freeze

  def examples
    ROUTES.values.flat_map do |row|
      op = row["wasm"]
      case row["translator"]
      when "numeric"
        op.match?(/f(?:32|64)/) ? float_examples(op) : integer_examples(op)
      when "constant" then constant_examples(op)
      when "control", "call" then control_examples(op)
      when "exception" then exception_examples(op)
      when "store" then store_examples(op)
      else raise "missing fixture family for #{op}"
      end
    end
  end

  def example(op, label, code, expected, type: "i32", preamble: "", locals: "", memory: "-", windows: "-", globals: "")
    route = ROUTES.fetch(op)
    mir = route["mir"]
    dispatch = case mir
               when "frame" then ["RETURN"]
               when "source"
                 # The state witness is on the designated source path.
                 preamble += ' (global $witness (mut i32) (i32.const 0))'
                 code = code.sub("<witness>", "i32.const 77 global.set $witness")
                 raise "missing source witness for #{op}" unless code.include?("global.set $witness")
                 globals = "i32:77"
                 ["GLOBAL_SET", "RETURN"]
               else [mir]
               end
    bits_export = if %w[f32 f64].include?(type)
                    carrier = type.sub("f", "i")
                    %((func (export "__bits") (result #{carrier}) call $run #{carrier}.reinterpret_#{type}))
                  end
    result = type ? "(result #{type})" : ""
    wat = %((module #{preamble} (func $run (export "run") #{result} #{locals} #{code}) #{bits_export}))
    expected = "#{type}:#{expected}" if expected.is_a?(Integer)
    observation = Observation.new(result: expected, memory: memory, globals: globals, dispatch: dispatch)
    Fixture.new(id: "#{op}/#{label}", wat: wat, windows: windows, steps: [["run", observation]],
      legacy: route["phase"] != "M1-EH")
  end

  def integer_examples(op)
    type, action = op.split(".")
    width = type.delete_prefix("i").to_i
    min = -(1 << (width - 1))
    max = -min - 1
    mask = (1 << width) - 1
    compare = {
      "eq" => :==, "ne" => :!=, "lt" => :<, "le" => :<=, "gt" => :>, "ge" => :>=
    }
    binary = %w[add sub mul div_s div_u rem_s rem_u and or xor shl shr_s shr_u rotl rotr]
    input = type
    result = type
    values = case action
             when "wrap_i64"
               input = "i64"
               [[7, 7], [0x12345678ffffffff, mask]]
             when "extend_i32_s", "extend_i32_u"
               input = "i32"
               [[7, 7], [-1, action.end_with?("_s") ? -1 : 0xffffffff]]
             when /\Aextend(\d+)_s\z/
               source_width = Regexp.last_match(1).to_i
               midpoint = 1 << (source_width - 1)
               [[midpoint - 1, midpoint - 1], [midpoint, -midpoint]]
             when "eqz"
               result = "i32"
               [[7, 0], [0, 1]]
             when "clz" then [[1, width - 1], [0, width]]
             when "ctz" then [[8, 3], [0, width]]
             when "popcnt" then [[7, 3], [-1, width]]
             else
               if binary.include?(action)
                 words = case action
                         when "add" then [[7, 3, 10], [max, 1, min]]
                         when "sub" then [[7, 3, 4], [min, 1, max]]
                         when "mul" then [[7, 3, 21], [min, -1, min]]
                         when "div_s" then [[-7, 3, -2], [min, 1, min], [7, 0, "trap:zero"], [min, -1, "trap:overflow"]]
                         when "div_u" then [[7, 3, 2], [-1, 2, max], [7, 0, "trap:zero"]]
                         when "rem_s" then [[-7, 3, -1], [min, -1, 0], [7, 0, "trap:zero"]]
                         when "rem_u" then [[7, 3, 1], [-1, 2, 1], [7, 0, "trap:zero"]]
                         when "and" then [[7, 3, 3], [-1, min, min]]
                         when "or" then [[7, 8, 15], [min, max, -1]]
                         when "xor" then [[7, 3, 4], [-1, max, min]]
                         when "shl" then [[7, 2, 28], [min + 1, width + 1, 2]]
                         when "shr_s" then [[-7, 2, -2], [min, width + 1, min / 2]]
                         when "shr_u" then [[7, 2, 1], [min, width + 1, -min / 2]]
                         when "rotl" then [[1, 2, 4], [min + 1, width + 1, 3]]
                         when "rotr" then [[8, 2, 2], [min + 1, width + 1, min + (-min / 2)]]
                         end
                 words
               else
                 result = "i32"
                 operator = compare.fetch(action.split("_").first)
                 a = action.end_with?("_u") ? mask : -1
                 [[7, 3, 7.public_send(operator, 3) ? 1 : 0], [-1, 1, a.public_send(operator, 1) ? 1 : 0]]
               end
             end
    values.each_with_index.map do |(*operands, expected), index|
      label = %w[normal boundary trap trap_overflow].fetch(index)
      expected = integer_carrier(result, expected) if expected.is_a?(Integer)
      example(op, label, "#{operands.map { |value| "#{input}.const #{value}" }.join(' ')} #{op}", expected, type: result)
    end
  end

  def literal_bits(type, literal)
    value = { "inf" => Float::INFINITY, "-inf" => -Float::INFINITY }.fetch(literal) { Float(literal) }
    type == "f32" ? [value].pack("e").unpack1("V") : [value].pack("E").unpack1("q<")
  end

  def float_vectors_by_op
    @float_vectors_by_op ||= (float_alu_cases + float_conversion_cases).group_by(&:first)
  end

  def float_examples(op)
    vectors = float_vectors_by_op.fetch(op)
    normal = vectors.find do |_, operands, _, expected|
      !operands.match?(/\b(?:nan|inf)\b/) && !%w[nan overflow invalid].include?(expected)
    end
    boundary = vectors.reverse.find { |vector| vector != normal && !%w[overflow invalid].include?(vector.last) }
    if boundary.nil?
      # Sign operations and single reinterpret fixtures need a second bit pattern.
      type = normal[2]
      boundary = case op
                 when /\.abs$/ then [op, "#{type}.const -1", type, "1"]
                 when /\.neg$/ then [op, "#{type}.const 1", type, "-1"]
                 when "i32.reinterpret_f32" then [op, "f32.const -0", "i32", 0x80000000]
                 when "i64.reinterpret_f64" then [op, "f64.const -0", "i64", -(1 << 63)]
                 when "f32.reinterpret_i32" then [op, "i32.const 0x1", "f32", "0x1p-149"]
                 when "f64.reinterpret_i64" then [op, "i64.const 0x1", "f64", "0x1p-1074"]
                 end
    end
    normal ||= vectors.first
    invalid = vectors.find { |vector| vector.last == "invalid" }
    overflow = vectors.find { |vector| vector.last == "overflow" }
    { normal: normal, boundary: boundary, trap: invalid, trap_overflow: overflow }.filter_map do |label, vector|
      next if vector.nil?
      _, operands, type, expected = vector
      encoded = case expected
                when Integer then expected
                when "invalid", "overflow" then "trap:#{expected}"
                when "nan" then "#{type}:#{operands.include?('nan:') ? 'qnan' : 'cnan'}"
                else literal_bits(type, expected)
                end
      example(op, label, "#{operands} #{op}", encoded, type: type)
    end
  end

  def constant_examples(op)
    type = op.split(".").first
    values = case type
             when "i32" then [["7", 7], ["-1", 0xffffffff]]
             when "i64" then [["7", 7], ["-9223372036854775808", -(1 << 63)]]
             when "f32", "f64" then [["1.25", literal_bits(type, "1.25")], ["-0", literal_bits(type, "-0")]]
             end
    values.zip(%w[normal boundary]).map do |(literal, expected), label|
      example(op, label, "#{op} #{literal}", expected, type: type)
    end
  end

  def control_examples(op)
    return [example(op, "trap", "unreachable", "trap:unreachable", type: nil)] if op == "unreachable"

    %w[normal boundary].map.with_index do |label, index|
      value = index.zero? ? 17 : 0xffffffff
      opposite = 1 - index
      extra = {}
      code, expected = case op
                       when "nop" then ["nop <witness> i32.const #{value}", value]
                       when "block" then ["block (result i32) <witness> i32.const #{value} end", value]
                       when "loop" then ["loop (result i32) <witness> i32.const #{value} end", value]
                       when "if" then ["i32.const #{opposite} if (result i32) i32.const 17 else i32.const -1 end", value]
                       when "else" then ["i32.const 0 if (result i32) unreachable else <witness> i32.const #{value} end", value]
                       when "end" then ["block (result i32) i32.const #{value} end <witness> i32.const 1 i32.xor", value ^ 1]
                       when "br" then ["block (result i32) i32.const #{value} br 0 unreachable end", value]
                       when "br_if"
                         extra[:locals] = "(local i32)"
                         ["i32.const 17 local.set 0 block i32.const #{opposite} br_if 0 i32.const -1 local.set 0 end local.get 0", value]
                       when "br_table"
                         ["block (result i32) block (result i32) i32.const #{value} i32.const #{index.zero? ? 0 : -1} br_table 0 1 end i32.const 1 i32.add end",
                           index.zero? ? value + 1 : value]
                       when "return" then ["i32.const #{value} return unreachable", value]
                       when "drop" then ["i32.const #{value} i64.const -1 drop <witness>", value]
                       when "select" then ["i32.const 17 i32.const -1 i32.const #{opposite} select", value]
                       when "local.get", "local.set", "local.tee"
                         extra[:locals] = "(local i32)"
                         body = case op
                                when "local.get", "local.set" then "i32.const #{value} local.set 0 local.get 0"
                                when "local.tee" then "i32.const #{value} local.tee 0 drop local.get 0"
                                end
                         [body, value]
                       when "call", "call_indirect"
                         extra[:preamble] = "(type $t (func (param i32) (result i32))) (func $target (type $t) local.get 0)"
                         if op == "call_indirect"
                           extra[:preamble] += " (table 2 funcref) (elem (i32.const 0) func $target)"
                           ["i32.const #{value} i32.const 0 call_indirect (type $t)", value]
                         else
                           ["i32.const #{value} call $target", value]
                         end
                       end
      example(op, label, code, expected, **extra)
    end.tap do |fixtures|
      if op == "call_indirect"
        preamble = "(type $t (func (result i32))) (table 1 funcref)"
        fixtures << example(op, "trap", "i32.const 0 call_indirect (type $t)", "trap:indirect", preamble: preamble)
      end
    end
  end

  def exception_examples(op)
    preamble = "(tag $t (param i32))"
    rethrow = "block (result exnref) try_table (catch_all_ref 0) i32.const 17 throw $t end unreachable end throw_ref"
    caught = "block (result i32) try_table (catch $t 0) %s end unreachable end"
    normal = op == "throw_ref" ? caught % rethrow : caught % "i32.const 17 throw $t"
    boundary = op == "throw_ref" ? caught % rethrow.sub("const 17", "const -1") : caught % "i32.const -1 throw $t"
    fixtures = [example(op, "normal", normal, 17, preamble: preamble),
      example(op, "boundary", boundary, 0xffffffff, preamble: preamble)]
    return fixtures if op == "try_table"

    code = op == "throw_ref" ? rethrow : "i32.const 17 throw $t"
    fixtures << example(op, "trap", code, "exception:i32:17", preamble: preamble, type: nil)
  end

  def store_examples(op)
    return memory_access_examples(op) if op.match?(/\.(?:load|store)/)
    case op
    when "global.get", "global.set"
      %w[normal boundary].zip([17, 0xffffffff]).map do |label, value|
        set = op == "global.set"
        preamble = "(global $g (mut i32) (i32.const #{set ? 0 : value}))"
        code = "#{set ? "i32.const #{value} global.set $g " : ''}global.get $g"
        example(op, label, code, value, preamble: preamble, globals: "i32:#{value}")
      end
    when "memory.size"
      [1, 0].zip(%w[normal boundary]).map do |pages, label|
        example(op, label, op, pages, preamble: "(memory #{pages} 2)", memory: "#{pages}:#{pages * PAGE}:")
      end
    when "memory.grow"
      [1, 2].zip(%w[normal boundary]).map do |delta, label|
        pages = delta == 1 ? 2 : 1
        example(op, label, "i32.const #{delta} #{op}", delta == 1 ? 1 : 0xffffffff,
          preamble: "(memory 1 2)", memory: "#{pages}:#{pages * PAGE}:")
      end
    else
      bulk_examples(op)
    end
  end

  def memory_access_examples(op)
    type, action = op.split(".")
    width = action[/\d+/]&.to_i&./(8) || (type.end_with?("32") ? 4 : 8)
    store = action.start_with?("store")
    bytes = Array.new(width) { |index| 0x81 + index }
    raw = bytes.each_with_index.sum { |value, index| value << (index * 8) }
    literal = bytes.map { |value| "\\%02x" % value }.join
    hex = bytes.pack("C*").unpack1("H*")
    [1, PAGE - width, PAGE - width + 1].zip(%w[normal boundary trap]).map do |address, label|
      trap = label == "trap"
      offset = trap ? 1 : address
      preamble = "(memory 1 2)"
      preamble += %( (data (i32.const #{offset}) "#{literal}")) unless store
      code = "i32.const #{address}"
      result_type = type
      if store
        carrier = type.sub("f", "i")
        code += " #{carrier}.const #{raw}"
        code += " #{type}.reinterpret_#{carrier}" if carrier != type
        result_type = nil
        expected = "void"
      else
        extended = action.end_with?("_s") ? raw - (1 << (width * 8)) : raw
        expected = integer_carrier(type.sub("f", "i"), extended)
      end
      code += " #{op} align=1"
      expected = "trap:bounds" if trap
      memory_hex = store && trap ? "00" * width : hex
      memory = "1:#{PAGE}:#{memory_hex}"
      window_start = store && trap ? PAGE - width : offset
      example(op, label, code, expected, type: result_type, preamble: preamble,
        windows: "#{window_start}:#{width}", memory: memory)
    end
  end

  def bulk_examples(op)
    preamble = "(memory 1 2)"
    values = case op
             when "memory.init"
               preamble += ' (data $data "abcdefgh")'
               [["1 0 3", "0061626300000000"], ["2 7 1", "0000680000000000"], ["0 7 2", "0000000000000000"]]
             when "memory.copy"
               preamble += ' (data (i32.const 0) "abcdefgh")'
               [["4 0 3", "6162636461626368"], ["1 0 6", "6161626364656668"], ["0 65535 2", "6162636465666768"]]
             when "memory.fill"
               [["1 171 3", "00ababab00000000"], ["2 256 2", "0000000000000000"], ["65535 7 2", "0000000000000000"]]
             end
    values.zip(%w[normal boundary trap]).map do |(operands, hex), label|
      code = operands.split.map { |arg| "i32.const #{arg}" }.join(" ")
      code += " #{op}"
      code += " $data" if op == "memory.init"
      example(op, label, code, label == "trap" ? "trap:bounds" : "void", type: nil,
        preamble: preamble, windows: "0:8", memory: "1:#{PAGE}:#{hex}")
    end
  end
end
