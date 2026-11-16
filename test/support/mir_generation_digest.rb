# frozen_string_literal: true

# Usage: ruby -ILIB test/support/mir_generation_digest.rb FIXTURE [matrix]
# Digest value-only MIR and decoded function bodies across source checkouts.
require "digest"
require "json"
require "wardite"

module MIRGenerationDigest
  def self.signature(entry)
    [entry.kind, entry.defined_index, entry.host_index, entry.parameter_types, entry.result_types]
  end

  def self.handlers(handlers)
    handlers.map do |handler|
      handler.clauses.map do |clause|
        [clause.tag_index, clause.payload_registers, clause.reference_register, clause.target_pc, clause.handler_depth]
      end
    end
  end

  def self.ir(ir)
    digest = Digest::SHA256.new
    digest << JSON.generate(ir.entries.map { |entry| signature(entry) })
    digest << JSON.generate(ir.hosts.map { |host| signature(host.entry) })
    ir.functions.each do |fn|
      digest << JSON.generate([
        fn.index, fn.pool_index, fn.parameter_types, fn.result_types, fn.local_count,
        fn.register_types, fn.initial_registers, fn.constant_registers,
        fn.uses_i64, fn.uses_float, fn.uses_eh, fn.uses_store, fn.uses_dynamic_calls,
        fn.instructions.map { |insn| Array.new(insn.size) { |i| insn[i] } },
        fn.dynamic_sites.map { |site| [site.host_index, site.table_index, site.arguments, site.parameter_types, site.result_types] },
        fn.memory_sites.map { |site| [site.sources, site.memory_index, site.source_memory_index, site.data_index] },
        fn.throw_sites.map { |site| [site.tag_index, site.payload_registers] },
        handlers(fn.handlers), fn.bytecode, handlers(fn.flat_handlers),
        fn.calls.map { |site| [site.callee.index, site.arguments] }
      ])
    end
    digest.hexdigest
  end

  def self.bodies(instance)
    digest = Digest::SHA256.new
    instance.code_section&.func_codes&.each do |body|
      instructions = body.body.map do |namespace, code, operands, else_pc, end_pc|
        values = operands.map do |operand|
          case operand
          when Wardite::Block then [operand.block_types, operand.type_index, operand.parameter_types, operand.result_types]
          when Wardite::FloatImmediate then [operand.type, operand.bits]
          when Wardite::OperandVector then operand.entries
          else operand
          end
        end
        [namespace, code, values, else_pc, end_pc]
      end
      digest << JSON.generate([body.locals_count, body.locals_type, instructions])
    end
    digest.hexdigest
  end
end

if $PROGRAM_NAME == __FILE__
  fixture = ARGV.fetch(0)
  settings = [[[], false]]
  if ARGV[1] == "matrix"
    toggles = [[]] + ([:all] + Wardite::Efflorescence::Configuration::FEATURES).map { |feature| [feature] }
    settings = toggles.product([false, true])
  end
  puts JSON.generate(settings.map do |disabled, profile|
    instance = File.open(fixture, "rb") do |file|
      Wardite::BinaryLoader.load_from_buffer(file, engine: :efflorescence,
        disabled_optimizations: disabled, mir_profile: profile)
    end
    vm = instance.runtime
    {
      disabled: disabled, profile: profile, decoded: MIRGenerationDigest.bodies(instance),
      semantic: MIRGenerationDigest.ir(vm.semantic_ir), optimized: MIRGenerationDigest.ir(vm.ir)
    }
  end)
end
