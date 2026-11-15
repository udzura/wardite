# frozen_string_literal: true

# Diagnostic CRuby run; allocations and inclusive times, not native timings.
require "json"
require "digest"
require "wardite"
require "vernier"

module GenerationAllocations
  TOTALS = Hash.new { |hash, key| hash[key] = {seconds: 0.0, objects: 0, calls: 0} }
  FUNCTIONS = []

  def self.wrap(klass, method, name)
    klass.prepend(Module.new do
      define_method(method) do |*args, **kwargs, &block|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        allocated = GC.stat(:total_allocated_objects)
        begin
          super(*args, **kwargs, &block)
        ensure
          seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          objects = GC.stat(:total_allocated_objects) - allocated
          total = TOTALS[name]
          total[:seconds] += seconds
          total[:objects] += objects
          total[:calls] += 1
          if name == :validate
            function = args.first
            FUNCTIONS << {index: function.index, seconds: seconds, objects: objects,
                          instructions: function.instructions.size, registers: function.register_count}
          end
        end
      end
      private method if klass.private_method_defined?(method)
    end)
  end
end

eff = Wardite::Efflorescence
decode_method = Wardite::BinaryLoader.respond_to?(:decode_body) ? :decode_body : :code_body
revision = ENV.fetch("MIR_GENERATION_REVISION") { IO.popen(["git", "rev-parse", "HEAD"], &:read).strip }
[
  [Wardite::BinaryLoader.singleton_class, :sections, :sections],
  [Wardite::BinaryLoader.singleton_class, decode_method, :code_body],

  [Wardite::CodeSection::CodeBody, :check_features, :features],
  [eff::Translator, :translate, :translate],
  [eff::Optimizer, :optimize, :optimize],
  [eff::IR, :copy, :ir_copy],
  [eff::RegisterValidation, :validate, :validate],
  [eff::RegisterValidation, :validate_types, :validate_types],
  [eff::Analysis, :initialize, :analysis],
  [eff::FlowGraph, :initialize, :flow_graph],
  [eff::Lowerer, :compile, :lower]
].each { |klass, method, name| GenerationAllocations.wrap(klass, method, name) }
fixture = File.expand_path(ARGV.fetch(0))
before = GC.stat
profile = Vernier.profile do
  instance = File.open(fixture, "rb") { |file| Wardite::BinaryLoader.load_from_buffer(file, engine: :efflorescence) }
  raise "Use a fixture without a start section" if instance.start_section
end
after = GC.stat
File.write(ARGV.fetch(1), JSON.pretty_generate(
  ruby: RUBY_DESCRIPTION, vernier: Vernier::VERSION,
  fixture: {path: fixture, sha256: Digest::SHA256.file(fixture).hexdigest},
  revision: revision,
  phases_inclusive: GenerationAllocations::TOTALS,
  gc_delta: before.keys.to_h { |key| [key, after[key] - before[key]] },
  slowest_validation: GenerationAllocations::FUNCTIONS.sort_by { |row| -row[:seconds] }.take(20),
  top_self_samples: Vernier::Output::Top.new(profile).output
))
