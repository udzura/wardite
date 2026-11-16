# frozen_string_literal: true

# CRuby diagnostic. Count visits in a cache-disabled load separately from timing.
require "digest"
require "json"
require "wardite"

eff = Wardite::Efflorescence
propagate = eff::Passes::CopyPropagation.instance_method(:propagate)
counts = {
  propagate: 0, resolve: 0, write: 0, bind: 0, next_block: 0,
  alias_arrays_initialized: 0, alias_cells_initialized: 0,
  destination_scan_cells: 0, leader_reset_cells: 0
}
traces = []
traces << [TracePoint.new(:call) { counts[:propagate] += 1 }, {target: propagate}]

if eff::Passes.const_defined?(:CopyAliases, false)
  aliases = eff::Passes::CopyAliases
  %i[resolve write bind next_block].each do |operation|
    traces << [TracePoint.new(:call) { counts[operation] += 1 }, {target: aliases.instance_method(operation)}]
  end
  initialize_trace = TracePoint.new(:return) do |event|
    state = event.self
    arrays = state.instance_variables.map { |ivar| state.instance_variable_get(ivar) }.grep(Array)
    counts[:alias_arrays_initialized] += arrays.size
    counts[:alias_cells_initialized] += arrays.sum(&:size)
  end
  traces << [initialize_trace, {target: aliases.instance_method(:initialize)}]
else
  # The old implementation has inline loops. Trace their entry lines once each
  # and count the size of the array they initialize or scan.
  source, first = propagate.source_location
  lines = File.readlines(source).drop(first).take_while { |line| line != "        end\n" }
  probes = {
    "aliases = (0...function.register_count).to_a" => ->(frame) do
      counts[:alias_arrays_initialized] += 1
      counts[:alias_cells_initialized] += frame.local_variable_get(:function).register_count
    end,
    "aliases = (0...function.register_count).to_a if analysis.leaders[pc] == 1" => ->(frame) do
      if frame.local_variable_get(:analysis).leaders[frame.local_variable_get(:pc)] == 1
        size = frame.local_variable_get(:function).register_count
        counts[:alias_arrays_initialized] += 1
        counts[:alias_cells_initialized] += size
        counts[:leader_reset_cells] += size
        counts[:next_block] += 1
      end
    end,
    "aliases.each_with_index do |source, register|" => ->(frame) do
      counts[:destination_scan_cells] += frame.local_variable_get(:aliases).size
      counts[:write] += 1
      counts[:bind] += 1 if frame.local_variable_get(:instruction)[0] == eff::Opcode::COPY
    end,
    "instruction[position] = aliases.fetch(instruction[position])" => ->(_) do
      counts[:resolve] += 1
    end
  }
  probes.each do |line, count|
    offset = lines.index { |statement| statement.strip == line } || abort("Missing legacy probe: #{line}")
    trace = TracePoint.new(:line) { |event| count.call(event.binding) }
    traces << [trace, {target: propagate, target_line: first + offset + 1}]
  end
end

wasm = ARGV.fetch(0)
begin
  traces.each { |trace, options| trace.enable(**options) }
  File.open(wasm, "rb") { |file| Wardite::BinaryLoader.load_from_buffer(file, engine: :efflorescence) }
ensure
  traces.each { |trace, _| trace.disable }
end
puts JSON.generate(sha256: Digest::SHA256.file(wasm).hexdigest, counts: counts)
