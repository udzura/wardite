# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

module CoreSpec
  REV = "977f97014c962f7bd1291fcc6d28b41a924882bf" # wg-1.0
  BASIC = %w[i32 i64 f32 f64 f32_bitwise f64_bitwise f32_cmp f64_cmp conversions
             int_exprs float_misc float_memory local_get local_set local_tee globals load store address align endianness
             memory_size memory_grow memory_trap block loop if br br_if br_table
             return call call_indirect select nop unreachable traps].freeze

  def self.commands(name, dir)
    filename = "#{name}.wast"
    source = if ENV["SPEC_CORE_DIR"]
      File.read(File.join(ENV.fetch("SPEC_CORE_DIR"), filename))
    else
      data, status = Open3.capture2("curl", "-fsSL", "--retry", "2",
        "https://raw.githubusercontent.com/WebAssembly/spec/#{REV}/test/core/#{filename}")
      raise "failed to fetch #{filename}" unless status.success?
      data
    end
    # wg-1.0 predates WABT's typed NaN expectations. Keep one line per assertion.
    source = source.gsub(/^\(assert_return_(canonical|arithmetic)_nan (\(invoke "([^"]+)".*\))\)$/) do
      kind, action, field = Regexp.last_match.captures
      type = [name, field.split(".").first].find { |s| %w[f32 f64].include?(s) }
      raise "unknown NaN result type for #{field}" unless type
      "(assert_return #{action} (#{type}.const nan:#{kind}))"
    end
    File.write(File.join(dir, filename), source)
    system("wast2json", filename, "-o", "#{name}.json", chdir: dir, exception: true)
    JSON.parse(File.read(File.join(dir, "#{name}.json"))).fetch("commands")
  end

  def self.value(v)
    type, bits = v.fetch_values("type", "value")
    unless bits.start_with?("nan:")
      bits = Integer(bits)
      bits -= 1 << 64 if type.end_with?("64") && bits >= 1 << 63
    end
    "#{type}:#{bits}"
  end

  def self.matches?(expected, actual)
    return true if expected == actual
    return actual.start_with?("validation:") if expected == "invalid module"
    return false unless expected.include?(":nan:") && actual.match?(/\Af(32|64):-?\d+\z/)
    type, _, kind = expected.split(":")
    result_type, bits = actual.split(":")
    return false unless result_type == type
    mask, quiet = type == "f32" ? [0x7fffffff, 0x7fc00000] : [0x7fffffffffffffff, 0x7ff8000000000000]
    magnitude = Integer(bits) & mask
    kind == "canonical" ? magnitude == quiet : magnitude >= quiet
  end

  def self.command_row(cmd, current, dir)
    op = cmd.fetch("type")
    case op
    when "module", "assert_invalid", "assert_malformed"
      return if op == "assert_malformed" && cmd.fetch("module_type") != "binary"
      operation, expected = case op
      when "module" then ["module", "loaded"]
      when "assert_invalid" then ["invalid", "invalid module"]
      else ["malformed", "malformed:#{cmd.fetch('text')}"]
      end
      [[operation, current, File.join(dir, cmd.fetch("filename"))], expected]
    when "action", "assert_return", "assert_trap"
      action = cmd.fetch("action", {})
      return unless %w[invoke get].include?(action["type"])
      args = action.fetch("args", []).map { |v| value(v) }
      expected = case op
      when "action" then "action completed"
      when "assert_trap" then "trap:#{cmd.fetch('text')}"
      else cmd.fetch("expected").map { |v| value(v) }.join(",")
      end
      [[action.fetch("type"), action.fetch("module", current), action.fetch("field"), *args],
       expected.empty? ? "void" : expected]
    end
  end

  def self.display(value)
    value.sub(/\Af(32|64):(-?\d+)\z/) do
      width, bits = Regexp.last_match.captures.map(&:to_i)
      "f%d:0x%0*x" % [width, width / 4, bits % (1 << width)]
    end
  end

  def self.run(name, dir, worker)
    cases = commands(name, dir)
    current = "-"
    rows = cases.map.with_index do |cmd, index|
      if cmd["type"] == "module"
        current = cmd.fetch("name", index.to_s)
      end
      command_row(cmd, current, dir)
    end
    plan = File.join(dir, "plan")
    output = File.join(dir, "#{name}.results")
    File.write(plan, rows.compact.map { |fields, _| fields.join("\t") + "\n" }.join)
    ok = system({"WARDITE_MIR_JIT" => "0"}, worker, plan, output)
    results = File.exist?(output) ? File.readlines(output, chomp: true) : []
    cursor = 0
    counts = Hash.new(0)
    cases.zip(rows).each do |cmd, row|
      action = cmd.fetch("action", {})
      field = action.fetch("field", cmd["type"])
      actual = row ? results[cursor] : "unsupported #{cmd['type']}"
      cursor += 1 if row
      # Execute all preceding commands even when focusing the report on an export.
      next if ENV["FILTER_FIELD"] && field != ENV["FILTER_FIELD"]
      expected = row&.last || cmd["text"] || cmd["type"]
      passed = if expected == "action completed"
        actual&.match?(/\A(void|[if](32|64):-?\d+)\z/)
      else
        actual && matches?(expected, actual)
      end
      status = row.nil? ? "SKIP" : passed ? "PASS" : "FAIL"
      counts[status] += 1
      if ENV["VERBOSE"] == "1" || status == "FAIL" && counts["FAIL"] <= 5
        label = field
        if action["type"] == "invoke"
          args = action.fetch("args").map { |v| display(value(v)) }
          label = "#{field}(#{args.join(', ')})"
        end
        expectation = expected == "invalid module" ? "#{expected} (#{cmd['text']})" : display(expected)
        puts "  #{status}  #{name}.wast:#{cmd['line']}  #{label}  expected #{expectation}  got #{display(actual || 'worker stopped')}"
      end
    end
    unless ok && results.size == cursor
      warn "#{name}: worker exited #{$?} after #{results.size}/#{cursor} commands"
      counts["FAIL"] += 1
    end
    puts "%-18s %5d pass  %4d fail  %4d skip" % [name, *%w[PASS FAIL SKIP].map { |key| counts[key] }]
    counts
  end
end

if $PROGRAM_NAME == __FILE__
  names = ARGV.empty? ? CoreSpec::BASIC : ARGV
  abort "invalid suite name" unless names.all? { |n| n.match?(/\A[a-z0-9_-]+\z/) }
  Dir.mktmpdir("wardite-spec") do |dir|
    worker = File.join(dir, "worker")
    log, status = Open3.capture2e(ENV.fetch("SPINEL", "spinel"), "--strict-require", "-O2",
      "-I#{File.expand_path('../lib', __dir__)}", File.join(__dir__, "spinel_worker.rb"), "-o", worker)
    abort log unless status.success?
    puts "WebAssembly wg-1.0  |  Spinel / Efflorescence  |  JIT off"
    totals = Hash.new(0)
    names.each do |name|
      CoreSpec.run(name, dir, worker).each { |key, n| totals[key] += n }
    end
    puts "Total: #{totals['PASS']} pass, #{totals['FAIL']} fail, #{totals['SKIP']} skip"
    exit(totals["FAIL"].zero? && totals["PASS"].positive?)
  end
end
