# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    class Metrics
      attr_reader :opcode_counts #: Array[Integer]
      attr_reader :register_reads #: Integer
      attr_reader :register_writes #: Integer
      attr_accessor :frames_created #: Integer
      attr_accessor :host_calls #: Integer
      attr_accessor :root_defined_entries #: Integer

      def initialize
        @opcode_counts = Array.new(Opcode::NAMES.size, 0)
        @register_reads = 0
        @register_writes = 0
        @frames_created = 0
        @host_calls = 0
        @root_defined_entries = 0
        @indirect_defined_entries = 0
      end

      # @rbs opcode: Integer
      # @rbs reads: Integer
      # @rbs writes: Integer
      # @rbs return: void
      def record(opcode, reads, writes)
        @opcode_counts[opcode] += 1
        @register_reads += reads
        @register_writes += writes
      end

      # @rbs return: Integer
      def dispatches
        @opcode_counts.sum
      end

      # @rbs return: Integer
      def copies
        @opcode_counts[Opcode::COPY]
      end

      # @rbs parameter_count: Integer
      # @rbs return: void
      def enter_indirect_defined(parameter_count)
        @indirect_defined_entries += 1
        @register_writes += parameter_count
      end

      # @rbs return: Integer
      def indirect_calls
        @opcode_counts[Opcode::CALL_INDIRECT]
      end

      # @rbs return: Integer
      def function_entries
        @root_defined_entries + @opcode_counts[Opcode::CALL] + @indirect_defined_entries + @host_calls
      end

      # @rbs return: String
      def report
        counters = "dispatches=#{dispatches} copies=#{copies} register_reads=#{@register_reads} " \
          "register_writes=#{@register_writes} function_entries=#{function_entries} frames_created=#{@frames_created}"
        if @host_calls > 0 || indirect_calls > 0
          counters += " host_calls=#{@host_calls} indirect_calls=#{indirect_calls}"
        end
        counters
      end
    end

    # Profiling is compiled into a separate instrumented MIR. The ordinary
    # dispatch loop never tests an enabled flag or updates per-instruction stats.
    class Instrumentation
      # @rbs ir: Wardite::Efflorescence::IR
      # @rbs return: Wardite::Efflorescence::IR
      def instrument(ir)
        output = ir.copy
        output.functions.each do |function|
          rewrite = Rewrite.new(function)
          function.instructions.each_with_index do |instruction, pc|
            rewrite.mark(pc)
            reads = function.reads(instruction).size
            writes = Opcode.destination(instruction) >= 0 ? 1 : 0
            # Parameter copies and the eventual return destination write count
            # at CALL; callee RETURN accounts for reading the returned value.
            writes += instruction.size - 3 if instruction[0] == Opcode::CALL
            rewrite.emit(Instruction.new([Opcode::PROFILE, instruction[0], reads, writes]))
            rewrite.emit(instruction.copy)
          end
          rewrite.finish
        end
        output
      end
    end

    class Inspection
      # @rbs ir: Wardite::Efflorescence::IR
      # @rbs return: String
      def disassemble(ir)
        lines = [] #: Array[String]
        ir.hosts.each_with_index do |host, i|
          lines << "host #{i}: #{host.external.name} #{host.entry.parameter_types.inspect} -> #{host.entry.result_types.inspect}"
        end
        ir.functions.each do |function|
          lines << "function #{function.index}: params=#{function.parameter_count} locals=#{function.local_count} registers=#{function.register_count}"
          if function.uses_i64
            lines << "  types: #{function.register_types.inspect} -> #{function.result_types.inspect}"
            function.constant_registers.each do |register|
              lines << "  const r#{register}: #{function.initial_value(register)}"
            end
          end
          function.handlers.each_with_index do |handler, i|
            handler.clauses.each do |clause|
              lines << "  handler #{i}: tag=#{clause.tag_index} payload=#{clause.payload_registers.inspect} ref=#{clause.reference_register} target=#{clause.target_pc} depth=#{clause.handler_depth}"
            end
          end
          function.throw_sites.each_with_index do |site, i|
            lines << "  throw #{i}: tag=#{site.tag_index} payload=#{site.payload_registers.inspect}"
          end
          function.memory_sites.each_with_index do |site, i|
            lines << "  memory #{i}: sources=#{site.sources.inspect} memory=#{site.memory_index} source_memory=#{site.source_memory_index} data=#{site.data_index}"
          end
          function.dynamic_sites.each_with_index do |site, i|
            target = site.host_index >= 0 ? "host=#{site.host_index}" : "table=#{site.table_index}"
            lines << "  call #{i}: #{target} #{site.parameter_types.inspect} -> #{site.result_types.inspect} arguments=#{site.arguments.inspect}"
          end
          function.instructions.each_with_index do |instruction, pc|
            operands = [] #: Array[String]
            index = 1
            while index < instruction.size
              operands << instruction[index].to_s
              index += 1
            end
            name = Opcode::NAMES.fetch(instruction[0])
            lines << "  #{pc}: #{name} #{operands.join(', ')}"
          end
        end
        lines.join("\n")
      end

      # @rbs ir: Wardite::Efflorescence::IR
      # @rbs return: String
      def statistics(ir)
        instructions = 0
        copies = 0
        registers = 0
        ir.functions.each do |function|
          instructions += function.instructions.size
          copies += function.instructions.count { |instruction| instruction[0] == Opcode::COPY }
          registers += function.register_count
        end
        "instructions=#{instructions} copies=#{copies} registers=#{registers}"
      end
    end
  end
end
