# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    class Translator
      # Declaration data used by translation, independent of mutable runtime
      # slots. Keep only encoded code and declaration shapes for inspection.
      class ModuleSource
        attr_reader :code #: String?
        attr_reader :globals #: Array[Wardite::Global]
        attr_reader :types #: Array[Wardite::Type]
        attr_reader :tags #: Array[Wardite::Efflorescence::Tag]
        attr_reader :has_memory #: bool
        attr_reader :funcref_table #: bool
        attr_reader :has_data_count #: bool
        attr_reader :data_segments #: Integer

        # @rbs instance: Wardite::Instance
        # @rbs code: String?
        def initialize(instance, code = nil)
          @code = code
          @globals = instance.store.globals.map do |global|
            Wardite::Global.new do |copy|
              copy.type = global.type
              copy.mutable = global.mutable
              copy.value = global.value
            end
          end
          @types = instance.types.map { |type| Wardite::Type.new(type.callsig.dup, type.retsig.dup) }
          @tags = instance.tags.dup
          @has_memory = !instance.store.memories.empty?
          @funcref_table = instance.store.tables[0]&.type == :funcref
          @has_data_count = !instance.data_count_section.nil?
          @data_segments = instance.data_section&.segments&.size || 0
        end

        # @rbs return: Wardite::TypeSection
        def block_types
          section = Wardite::TypeSection.new
          @types.each do |type|
            section.defined_types << type.callsig
            section.defined_results << type.retsig
          end
          section
        end
      end
    end
  end
end
