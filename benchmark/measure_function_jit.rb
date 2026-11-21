# frozen_string_literal: true

require "open3"

module MeasureFunctionJIT
  def self.run(binary, name, args, result_type)
    ref, err, status = Open3.capture3("wasmtime", "run", "--invoke", name, *args)
    abort err unless status.success?
    result = Integer(ref)
    result %= 1 << 64 if result_type == "I64"
    expected = "return value: #{result_type}(#{result})"
    command = [binary, "--no-wasi", "--invoke", name, "--", *args]
    output, status = Open3.capture2e({"WARDITE_MIR_JIT" => "1", "WARDITE_TRACE" => "1"}, *command)
    events = output.lines.grep(/^MIR JIT function /)
    abort "JIT did not complete #{name}: #{output}" unless events.size == 1 && events.first.match?(/: compiled$/)
    abort output unless status.success? && output.lines.map(&:chomp).include?(expected)

    # Alternate the order within each pair. Include process startup, loading,
    # compilation and the native call. Discard two warmup pairs.
    samples = [[], []]
    11.times do |pair|
      (pair.even? ? [0, 1] : [1, 0]).each do |jit|
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        output, status = Open3.capture2e({"WARDITE_MIR_JIT" => jit.to_s, "WARDITE_TRACE" => nil}, *command)
        ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
        abort output unless status.success? && output.chomp == expected
        samples[jit] << ms if pair >= 2
      end
    end
    off, on = samples.map { |values| values.sort.fetch(values.size / 2) }
    [result, off, on]
  end
end
