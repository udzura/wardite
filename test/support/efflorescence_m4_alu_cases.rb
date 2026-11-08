# frozen_string_literal: true

module EfflorescenceM4ALUCases
  MODULUS = 2**64
  MIN = -2**63
  MAX = 2**63 - 1
  BOUNDS = [0, 1, -1, 2**31 - 1, 2**31, 2**31 + 1, 2**32 - 1, 2**32, 2**32 + 1,
            MAX - 1, MAX, MIN, MIN + 1, 0x5555555555555555, -0x5555555555555556].freeze
  SHIFTS = [0, 1, 31, 32, 33, 63, 64, 65, -1].freeze
  SIGNED_COMPARISONS = %w[eq ne lt_s gt_s le_s ge_s].zip(%i[== != < > <= >=]).to_h.freeze
  UNSIGNED_COMPARISONS = %w[lt_u gt_u le_u ge_u].zip(%i[< > <= >=]).to_h.freeze
  SHIFT_OPS = %w[shl shr_s shr_u rotl rotr].freeze
  BIT_OPS = { "and" => :&, "or" => :|, "xor" => :^ }.freeze

  def signed_field(value, bits)
    modulus = 2**bits
    (value + modulus / 2) % modulus - modulus / 2
  end

  def alu_cases
    operations = {}
    add = lambda do |operation, inputs, result, values, &reference|
      body = inputs.each_index.map { |i| "local.get #{i}" }.join(" ")
      wat = %((func (export "#{operation}") (param #{inputs.join(' ')}) (result #{result}) #{body} #{operation}))
      rows = values.map { |args| [operation, *args, reference.call(*args)] }
      operations[operation] = [wat, rows]
    end
    random = Random.new(0x64)
    pairs = BOUNDS.product(BOUNDS) + Array.new(128) { Array.new(2) { random.rand(MIN..MAX) } }
    words = (BOUNDS + pairs.flatten).uniq
    unary = words.map { |word| [word] }

    add.call("i64.eqz", [:i64], :i32, unary) { |a| a.zero? ? 1 : 0 }
    SIGNED_COMPARISONS.each do |op, compare|
      add.call("i64.#{op}", [:i64, :i64], :i32, pairs) { |a, b| a.public_send(compare, b) ? 1 : 0 }
    end
    UNSIGNED_COMPARISONS.each do |op, compare|
      add.call("i64.#{op}", [:i64, :i64], :i32, pairs) do |a, b|
        (a % MODULUS).public_send(compare, b % MODULUS) ? 1 : 0
      end
    end
    BIT_OPS.each do |op, calculate|
      add.call("i64.#{op}", [:i64, :i64], :i64, pairs) { |a, b| a.public_send(calculate, b) }
    end
    SHIFT_OPS.each do |op|
      add.call("i64.#{op}", [:i64, :i64], :i64, BOUNDS.product(SHIFTS) + pairs) do |a, b|
        count = b % 64
        unsigned = a % MODULUS
        result = case op
                 when "shl" then unsigned * 2**count
                 when "shr_s" then a.div(2**count)
                 when "shr_u" then unsigned.div(2**count)
                 when "rotl" then unsigned * 2**count + unsigned.div(2**(64 - count))
                 when "rotr" then unsigned.div(2**count) + (unsigned % 2**count) * 2**(64 - count)
                 end
        signed_field(result, 64)
      end
    end
    add.call("i64.clz", [:i64], :i64, unary) { |a| 64 - (a % MODULUS).bit_length }
    add.call("i64.ctz", [:i64], :i64, unary) { |a| a.zero? ? 64 : (a & -a).bit_length - 1 }
    add.call("i64.popcnt", [:i64], :i64, unary) { |a| (a % MODULUS).digits(2).count(1) }
    add.call("i32.wrap_i64", [:i64], :i32, unary) { |a| a % 2**32 }
    [8, 16, 32].each do |width|
      boundary = 2**(width - 1)
      cases = unary + [[boundary - 1], [boundary], [boundary + 1]]
      add.call("i64.extend#{width}_s", [:i64], :i64, cases) { |a| signed_field(a, width) }
    end
    i32_words = words.map { |a| [a % 2**32] }.uniq
    add.call("i64.extend_i32_s", [:i32], :i64, i32_words) { |a| signed_field(a, 32) }
    add.call("i64.extend_i32_u", [:i32], :i64, i32_words) { |a| a }

    { "add" => :+, "sub" => :-, "mul" => :* }.each do |op, calculate|
      add.call("i64.#{op}", [:i64, :i64], :i64, pairs) { |a, b| signed_field(a.public_send(calculate, b), 64) }
    end
    %w[div_s rem_s div_u rem_u].each do |op|
      add.call("i64.#{op}", [:i64, :i64], :i64, pairs) do |a, b|
        if b.zero?
          "zero"
        elsif op == "div_s" && a == MIN && b == -1
          "overflow"
        elsif op.end_with?("_u")
          unsigned_a, unsigned_b = a % MODULUS, b % MODULUS
          signed_field(op == "div_u" ? unsigned_a.div(unsigned_b) : unsigned_a % unsigned_b, 64)
        elsif op == "rem_s"
          a.remainder(b)
        else
          quotient = a.abs.div(b.abs)
          a.negative? == b.negative? ? quotient : -quotient
        end
      end
    end

    [operations.values.map(&:first).join("\n"), operations.values.flat_map(&:last)]
  end
end
