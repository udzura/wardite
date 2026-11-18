# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    class FunctionPreparer
      # @rbs ir: IR
      # @rbs configuration: Configuration
      # @rbs tags: Array[Tag]
      # @rbs profile: bool
      # @rbs cache: MIRCache?
      def initialize(ir, configuration, tags, profile, cache)
        @ir = ir
        @optimizer = Optimizer.new(configuration)
        @inline = configuration.enabled?(:inline)
        @inlining = Passes::Inlining.new
        @tags = tags
        @profile = profile
        @cache = cache
        @locals = {} #: Hash[Integer, Function]
        @leaves = {} #: Hash[Integer, Function]
      end

      # @rbs function: Function
      # @rbs return: void
      def prepare(function)
        if @cache
          @cache.restore_function(function)
          return
        end
        return unless function.bytecode.empty?

        body = @locals.delete(function.index) || optimize_local(function)
        if @inline && OptimizationScope.caller?(body)
          body.instructions.each do |instruction|
            next unless instruction[0] == Opcode::CALL
            target = @ir.function_at(instruction[2])
            next if target.index == body.index || !target.bytecode.empty? || @locals.key?(target.index)
            next unless @inlining.candidate?(target)
            @locals[target.index] = optimize_local(target)
          end
          @optimizer.optimize_function(body) if @inlining.expand_calls(body, @ir, @leaves)
        end
        RegisterValidation.new.validate(body, @ir, tags: @tags)
        Instrumentation.new.instrument_function(body) if @profile
        Lowerer.new.compile_function(body, @ir)
        function.install_prepared(body)
      end

      private

      # Preserve the pre-inlining leaf even if its own invocation happens first.
      # @rbs function: Function
      # @rbs return: Function
      def optimize_local(function)
        body = function.copy
        @optimizer.optimize_function(body)
        @leaves[body.index] = body.copy if @inline && @inlining.eligible?(body)
        body
      end
    end
  end
end
