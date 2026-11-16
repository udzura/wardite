# frozen_string_literal: true

# Count structural work in one cache-disabled load, separately from timings.
require "digest"
require "json"
require "wardite"

wasm = ARGV.fetch(0)
disabled = ARGV[1] == "no-inline" ? [:inline] : []
eff = Wardite::Efflorescence
inlining = eff::Passes::Inlining
counts = {
  ir_copies: 0, inline_runs: 0, expected: [0, 0, 0], snapshots: [0, 0, 0],
  copied_noncandidates: 0, rewrites: 0, changed_callers: 0
}
active = false

def count_function(stats, function)
  stats[0] += 1
  stats[1] += function.instructions.size
  stats[2] += function.register_count
end

ir_copies = TracePoint.new(:call) { counts[:ir_copies] += 1 }
run = TracePoint.new(:call, :return) do |event|
  if event.event == :call
    counts[:inline_runs] += 1
    active = true
    event.binding.local_variable_get(:ir).functions.each do |function|
      count_function(counts[:expected], function) if event.self.send(:eligible?, function)
    end
  else
    active = false
    counts[:changed_callers] += event.return_value.size
  end
end

# eligible? is stateless. Reuse it for the diagnostic without changing any IR.
predicate = inlining.new
snapshot = TracePoint.new(:call) do |event|
  if active
    count_function(counts[:snapshots], event.self)
    counts[:copied_noncandidates] += 1 unless predicate.send(:eligible?, event.self)
  end
end
rewrites = TracePoint.new(:call) { counts[:rewrites] += 1 if active }

traces = {
  ir_copies => eff::IR.instance_method(:copy),
  run => inlining.instance_method(:run),
  snapshot => eff::Function.instance_method(:copy),
  rewrites => eff::Rewrite.instance_method(:initialize)
}
begin
  traces.each { |trace, target| trace.enable(target: target) }
  File.open(wasm, "rb") do |file|
    Wardite::BinaryLoader.load_from_buffer(file, engine: :efflorescence, disabled_optimizations: disabled)
  end
ensure
  traces.each_key(&:disable)
end
puts JSON.generate(sha256: Digest::SHA256.file(wasm).hexdigest, disabled: disabled,
  count_order: %w[functions instructions registers], counts: counts)
