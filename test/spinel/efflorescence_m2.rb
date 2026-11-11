# frozen_string_literal: true
# rbs_inline: enabled

require 'wardite'

[:stack, :efflorescence].each do |engine|
  instance = File.open(ARGV.fetch(0), 'rb') do |file|
    Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false, engine: engine)
  end
  memory = instance.store.memories[0] || raise('missing memory')
  raise 'not binary' unless memory.buffer.is_a?(IO::Buffer)
  raise 'invalid byte length' unless memory.bytesize == 65536
  raise 'constant-expression decoding failed' unless Integer(memory.buffer.get_value(:U8, 11)) == 255
  global = instance.store.globals[0] || raise('missing global')
  value = global.value
  raise 'bad global initializer' unless value.is_a?(Wardite::I32) && value.value == 11
end
Wardite::Efflorescence::StoreAccess.check_range(65536, 0, 65536)
trapped = false
begin
  Wardite::Efflorescence::StoreAccess.check_range(65537, 0, 65536)
rescue Wardite::EvalError
  trapped = true
end
raise 'missing bounds trap' unless trapped
puts 'M2 foundation passed'
