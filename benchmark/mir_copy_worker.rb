# frozen_string_literal: true
# rbs_inline: enabled

# Measure Function#copy with independently controlled register and constant counts.
require "wardite"

registers = ARGV.fetch(0).to_i
constants = ARGV.fetch(1).to_i
copies = ARGV.fetch(2).to_i
raise "invalid copy workload" unless registers >= constants && constants >= 0 && copies > 0

source = Wardite::Efflorescence::Function.new(0, [], [], 0)
register = 0
while register < registers
  if register < constants
    source.allocate_constant(register)
  else
    source.allocate_register(register)
  end
  register += 1
end

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
copies.times do
  copy = source.copy
  raise "register copy differs" unless copy.initial_registers == source.initial_registers &&
    copy.constant_registers == source.constant_registers
end
puts Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
