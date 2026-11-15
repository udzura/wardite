# frozen_string_literal: true

# Insert timers into a disposable source copy (also compilable with Spinel).
# Usage: ruby benchmark/prepare_mir_generation_profile.rb BUILD_DIR [detail|none]
require "fileutils"
require "prism"

root = File.expand_path("..", __dir__)
destination = File.expand_path(ARGV.fetch(0))
abort "Use a new output directory" if File.exist?(destination)
detail = ARGV[1] == "detail"
abort "Unknown instrumentation mode" unless ARGV[1].nil? || %w[detail none].include?(ARGV[1])
instrument = ARGV[1] != "none"
targets = {
  "Wardite::BinaryLoader.sections" => "sections",
  "Wardite::CodeSection::CodeBody.check_features" => "features",
  "Wardite::Store.initialize" => "store",
  "Wardite::Efflorescence::Translator.link" => "link",
  "Wardite::Efflorescence::Translator.translate" => "translate",
  "Wardite::Efflorescence::Optimizer.optimize" => "optimize",
  "Wardite::Efflorescence::RegisterValidation.validate" => "validate",
  "Wardite::Efflorescence::Lowerer.compile" => "lower"
}
if detail
  targets.merge!({
    "Wardite::BinaryLoader.code_body" => "code_body",
    "Wardite::Efflorescence::IR.copy" => "ir_copy",
    "Wardite::Efflorescence::Passes::Inlining.run" => "inline",
    "Wardite::Efflorescence::Passes::CopyPropagation.run" => "copy_pass",
    "Wardite::Efflorescence::Passes::CopyPropagation.propagate" => "propagate",
    "Wardite::Efflorescence::Passes::ImmediateSpecialization.run" => "immediate",
    "Wardite::Efflorescence::Passes::BranchFusion.run" => "branch",
    "Wardite::Efflorescence::Passes::Superinstructions.run" => "superinstruction",
    "Wardite::Efflorescence::Analysis.initialize" => "analysis",
    "Wardite::Efflorescence::FlowGraph.initialize" => "flow_graph",
    "Wardite::Efflorescence::RegisterValidation.validate_types" => "validate_types",
    "Wardite::Efflorescence::RegisterValidation.reverse_postorder" => "reverse_postorder"
  })
end
FileUtils.mkdir_p(destination)
FileUtils.cp_r(File.join(root, "lib"), destination)
found = []
Dir[File.join(destination, "lib/**/*.rb")].each do |path|
  next unless instrument
  source = File.binread(path)
  edits = []
  walk = lambda do |node, nesting|
    if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
      nesting = [*nesting, node.constant_path.slice]
    elsif node.is_a?(Prism::DefNode)
      key = "#{nesting.join('::')}.#{node.name}"
      if (label = targets[key])
        abort "Already has ensure: #{key}" if node.body.is_a?(Prism::BeginNode) && node.body.ensure_clause
        id = targets.values.index(label)
        body = node.body.is_a?(Prism::BeginNode) ? node.body.statements : node.body
        edits << [body.location.start_offset, "mir_measure_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)\n"]
        edits << [node.end_keyword_loc.start_offset, "ensure\nMirGenerationMeasurement::SECONDS[#{id}] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - mir_measure_started\nMirGenerationMeasurement::COUNTS[#{id}] += 1\n"]
        found << key
      end
    end
    node.compact_child_nodes.each { |child| walk.call(child, nesting) }
  end
  walk.call(Prism.parse(source).value, [])
  edits.sort_by(&:first).reverse_each { |offset, text| source.insert(offset, text) }
  File.binwrite(path, source) unless edits.empty?
end
abort "Missing instrumentation: #{targets.keys - found}" if instrument && !(targets.keys - found).empty?
File.write(File.join(destination, "measurement.rb"), <<~RUBY)
  # frozen_string_literal: true
  # rbs_inline: enabled
  module MirGenerationMeasurement
    NAMES = #{targets.values.inspect}.freeze
    SECONDS = Array.new(#{targets.size}, 0.0) #: Array[Float]
    COUNTS = Array.new(#{targets.size}, 0) #: Array[Integer]
  end
RUBY
FileUtils.cp(File.join(root, "benchmark/mir_generation_worker.rb"), destination)
puts destination
