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
        attr_reader :function_types #: Array[String]
        attr_reader :declared_functions #: Array[Integer]
        attr_reader :type_keys #: Array[String]
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
          @type_keys = instance.type_section&.type_keys&.dup || []
          indices = instance.import_section.imports.map(&:sig_index) + (instance.function_section&.func_indices || [])
          @function_types = indices.map { |index| @type_keys.fetch(index) }
          elements = instance.elem_section
          @declared_functions = elements ? elements.declared_functions + elements.element_indices.flatten : []
          instance.export_section.exports.each_value { |desc| @declared_functions << desc.index if desc.kind == 0 }
          @tags = instance.tags.dup
          @has_memory = !instance.store.memories.empty?
          @funcref_table = instance.store.tables[0]&.type == :funcref
          @has_data_count = !instance.data_count_section.nil?
          @data_segments = instance.data_section&.segments&.size || 0
        end

        # @rbs return: Wardite::TypeSection
        def block_types
          section = Wardite::TypeSection.new
          section.type_keys.concat(@type_keys)
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
