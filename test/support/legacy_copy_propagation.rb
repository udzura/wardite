# frozen_string_literal: true

module LegacyCopyPropagation
  E = Wardite::Efflorescence

  # Keep the old eager invalidation algorithm as a differential reference.
  def self.propagate(function)
    analysis = E::Analysis.new(function)
    aliases = Array.new(function.register_count) { |register| register }
    rewrite = E::Rewrite.new(function)
    function.instructions.each_with_index do |original, pc|
      rewrite.mark(pc)
      aliases = Array.new(function.register_count) { |register| register } if analysis.leaders[pc] == 1
      instruction = original.copy
      E::Opcode.read_positions(instruction).each do |position|
        instruction[position] = aliases.fetch(instruction[position])
      end
      destination = E::Opcode.destination(instruction)
      if destination >= 0
        invalidate(aliases, destination)
        if instruction[0] == E::Opcode::COPY && instruction[2] != destination
          aliases[destination] = instruction[2]
        end
      end
      rewrite.emit(instruction)
    end
    rewrite.finish
  end

  def self.invalidate(aliases, destination)
    aliases.each_with_index do |source, register|
      aliases[register] = register if source == destination || register == destination
    end
  end
end
