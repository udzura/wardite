# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "optparse"
require_relative "wast_source"

module CoreSpec
  REVISIONS = {
    "wg-1.0" => "977f97014c962f7bd1291fcc6d28b41a924882bf",
    "wg-3.0" => "9d36019973201a19f9c9ebb0f10828b2fe2374aa",
  }.freeze
  VERSION = ENV.fetch("SPEC_VERSION", "wg-1.0")
  REV = REVISIONS.fetch(VERSION)
  EXCEPTIONS = %w[tag throw throw_ref try_table].map { |name| "exceptions/#{name}" }.freeze
  NUMERIC_TYPES = %w[i32 i64 f32 f64].freeze
  BASIC = %w[i32 i64 f32 f64 f32_bitwise f64_bitwise f32_cmp f64_cmp conversions
             int_exprs float_misc float_memory local_get local_set local_tee globals load store address align endianness
             memory_size memory_grow memory_trap block loop if br br_if br_table
             return call call_indirect select nop unreachable traps].freeze

  def self.commands(name, dir)
    path = "#{name}.wast"
    filename = File.basename(path)
    source = if ENV["SPEC_CORE_DIR"]
      File.read(File.join(ENV.fetch("SPEC_CORE_DIR"), path))
    else
      data, status = Open3.capture2("curl", "-fsSL", "--retry", "2",
        "https://raw.githubusercontent.com/WebAssembly/spec/#{REV}/test/core/#{path}")
      raise "failed to fetch #{filename}" unless status.success?
      data
    end
    # wg-1.0 predates WABT's typed NaN expectations. Keep one line per assertion.
    normalized = source.gsub(/^\(assert_return_(canonical|arithmetic)_nan (\(invoke "([^"]+)".*\))\)$/) do
      kind, action, field = Regexp.last_match.captures
      type = [name, field.split(".").first].find { |s| %w[f32 f64].include?(s) }
      raise "unknown NaN result type for #{field}" unless type
      "(assert_return #{action} (#{type}.const nan:#{kind}))"
    end
    File.write(File.join(dir, filename), normalized)
    args = [filename, "-o", "suite.json"]
    if VERSION == "wg-3.0"
      # Older wasm-tools releases reject full-width u64 memarg offsets.
      unless system("wasm-tools", "json-from-wast", *args, chdir: dir)
        warn "#{filename}: retrying conversion with WABT"
        system("wast2json", "--enable-all", *args, chdir: dir, exception: true)
      end
    else
      system("wast2json", *args, chdir: dir, exception: true)
    end
    [JSON.parse(File.read(File.join(dir, "suite.json"))).fetch("commands"), source]
  end

  def self.value(v)
    return "refnull" if v["type"] == "refnull" || v["value"] == "null"
    return "externref:#{v.fetch('value')}" if v["type"] == "externref"
    return "funcref" if v == {"type" => "funcref"}
    type, bits = v.fetch_values("type", "value")
    unless bits.start_with?("nan:")
      bits = Integer(bits)
      bits &= 0xffffffff if type.end_with?("32")
      bits -= 1 << 64 if type.end_with?("64") && bits >= 1 << 63
    end
    "#{type}:#{bits}"
  end

  def self.matches?(expected, actual)
    return true if expected == actual
    return actual.start_with?("syntax:") if expected == "malformed text"
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
    when "register"
      [["register", cmd.fetch("name", current), cmd.fetch("as")], "registered"]
    when "module", "assert_invalid", "assert_malformed", "assert_unlinkable"
      if cmd["module_type"] == "text" && op != "module"
        return unless VERSION == "wg-3.0" && op == "assert_malformed"
        file = cmd.fetch("filename")
        message, status = Open3.capture2e("wat2wasm", "--enable-all", "--no-check", file, "-o", "quoted.wasm", chdir: dir)
        diagnostic = message.lines.find { |line| line.include?("error:") }.to_s
        # WAST diagnostics illustrate the rejection. WABT uses different wording.
        actual = if status.success?
          "parsed"
        elsif status.exitstatus == 1 && diagnostic.match?(/:\d+:\d+: error:/)
          "syntax:#{diagnostic.split('error:', 2).last.strip}"
        else
          "converter failed: #{message.lines.first.to_s.strip}"
        end
        return [nil, "malformed text", actual]
      end
      operation, expected = case op
      when "module" then ["module", "loaded"]
      when "assert_unlinkable" then ["unlinkable", "unlinkable:#{cmd.fetch('text')}"]
      when "assert_invalid" then ["invalid", "invalid module"]
      else ["malformed", "malformed:#{cmd.fetch('text')}"]
      end
      [[operation, current, File.join(dir, cmd.fetch("filename"))], expected]
    when "action", "assert_return", "assert_trap", "assert_exception"
      action = cmd.fetch("action", {})
      return unless %w[invoke get].include?(action["type"])
      values = action.fetch("args", []) + cmd.fetch("expected", [])
      return unless values.all? { |v| NUMERIC_TYPES.include?(v["type"]) || v == {"type" => "funcref"} || v["type"] == "externref" || v["type"] == "refnull" || v == {"type" => "funcref", "value" => "null"} }
      args = action.fetch("args", []).map { |v| value(v) }
      expected = case op
      when "action" then "action completed"
      when "assert_exception" then "uncaught exception"
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

  def self.single_case(cases, target)
    indices = [target]
    cases.take(target).each_with_index do |command, i|
      indices << i if command["type"] == "register"
    end
    indices.dup.each do |i|
      command = cases.fetch(i)
      action = command["action"]
      next unless action || command["type"] == "register"
      name = action ? action["module"] : command["name"]
      setup = (0...i).reverse_each.find do |j|
        cases[j]["type"] == "module" && (!name || cases[j]["name"] == name)
      end
      indices << setup if setup
    end
    indices.uniq.sort
  end

  def self.run(name, dir, worker, line: nil, detailed: 0)
    name = "global" if VERSION == "wg-3.0" && name == "globals"
    cases, source = commands(name, dir)
    if detailed.positive? || line
      forms = source_forms(source)
      raise "#{name}: WAST command count differs from wast2json" unless forms.size == cases.size
    end
    if line
      matches = forms.each_index.select { |i| (forms[i].first_line..forms[i].last_line).cover?(line) }
      abort "#{name}.wast:#{line}: expected one WAST command, found #{matches.size}" unless matches.one?
      target = matches.first
      indices = single_case(cases, target)
      cases = cases.values_at(*indices)
      forms = forms.values_at(*indices)
    end
    current = "-"
    rows = cases.map.with_index do |cmd, index|
      if cmd["type"] == "module"
        current = cmd.fetch("name", index.to_s)
      end
      command_row(cmd, current, dir)
    end
    plan = File.join(dir, "plan")
    output = File.join(dir, "results")
    File.write(plan, rows.compact.filter_map { |fields, _| fields.join("\t") + "\n" if fields }.join)
    ok = system({"WARDITE_MIR_JIT" => "0"}, worker, plan, output)
    results = File.exist?(output) ? File.readlines(output, chomp: true) : []
    cursor = 0
    counts = Hash.new(0)
    cases.zip(rows).each_with_index do |(cmd, row), i|
      action = cmd.fetch("action", {})
      field = action.fetch("field", cmd["type"])
      actual = row ? (row[0] ? results[cursor] : row[2]) : "unsupported #{cmd['type']}"
      cursor += 1 if row && row[0]
      # Execute all preceding commands even when focusing the report on an export.
      next if ENV["FILTER_FIELD"] && field != ENV["FILTER_FIELD"]
      expected = row&.[](1) || cmd["text"] || cmd["type"]
      passed = if expected == "action completed"
        actual&.match?(/\A(void|[if](32|64):-?\d+)\z/)
      else
        actual && matches?(expected, actual)
      end
      status = row.nil? ? "SKIP" : passed ? "PASS" : "FAIL"
      # Report setup separately only when loading the selected module failed.
      next if line && i < cases.size - 1 && passed
      counts[status] += 1
      show_source = (status == "FAIL" && detailed >= 1) || (status == "SKIP" && detailed >= 2)
      if line || ENV["VERBOSE"] == "1" || show_source || (status == "FAIL" && counts["FAIL"] <= 5)
        label = field
        if action["type"] == "invoke"
          args = action.fetch("args").map { |v| NUMERIC_TYPES.include?(v["type"]) ? display(value(v)) : v.inspect }
          label = "#{field}(#{args.join(', ')})"
        end
        expectation = expected == "invalid module" ? "#{expected} (#{cmd['text']})" : display(expected)
        puts "  #{status}  #{name}.wast:#{cmd['line']}  #{label}  expected #{expectation}  got #{display(actual || 'worker stopped')}"
        if show_source
          form = forms.fetch(i)
          form.text.each_line.with_index(form.first_line) { |text, n| puts "    %5d | %s" % [n, text.chomp] }
        end
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
  line = nil
  detailed = {"1" => 1, "2" => 2}.fetch(ENV["DETAILED"], 0)
  OptionParser.new do |options|
    options.banner = "Usage: ruby spec/runner.rb [--detailed] [--line N] [SUITE ...]"
    options.on("--line N", Integer, "Execute one command with a fresh module") { |n| line = n }
    options.on("--detailed", "Print original WAST for every failure") { detailed = [detailed, 1].max }
  end.parse!
  abort "choose --line or FILTER_FIELD" if line && ENV["FILTER_FIELD"]
  names = ARGV.empty? ? CoreSpec::BASIC : ARGV
  names = CoreSpec::EXCEPTIONS if names == ["exceptions"] && CoreSpec::VERSION == "wg-3.0"
  abort "--line requires one suite and a positive line number" if line && (names.size != 1 || line < 1)
  valid_names = names.all? do |name|
    name.match?(/\A[a-z0-9_-]+\z/) || (CoreSpec::VERSION == "wg-3.0" && CoreSpec::EXCEPTIONS.include?(name))
  end
  abort "invalid suite name" unless valid_names
  Dir.mktmpdir("wardite-spec") do |dir|
    worker = File.join(dir, "worker")
    log, status = Open3.capture2e(ENV.fetch("SPINEL", "spinel"), "--strict-require", "-O2",
      "-I#{File.expand_path('../lib', __dir__)}", File.join(__dir__, "spinel_worker.rb"), "-o", worker)
    abort log unless status.success?
    puts "WebAssembly #{CoreSpec::VERSION}  |  Spinel / Efflorescence  |  JIT off"
    totals = Hash.new(0)
    names.each do |name|
      Dir.mktmpdir("suite", dir) do |suite_dir|
        CoreSpec.run(name, suite_dir, worker, line: line, detailed: detailed).each { |key, n| totals[key] += n }
      end
    end
    puts "Total: #{totals['PASS']} pass, #{totals['FAIL']} fail, #{totals['SKIP']} skip"
    exit(totals["FAIL"].zero? && totals["PASS"].positive?)
  end
end
