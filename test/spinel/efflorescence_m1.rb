# frozen_string_literal: true
# rbs_inline: enabled

require 'wardite'

[[], [:all], [:frames]].each do |disabled|
  [false, true].each do |profile|
    instance = File.open(ARGV.fetch(0), 'rb') do |file|
      Wardite::BinaryLoader.load_from_buffer(file, enable_wasi: false,
        engine: :efflorescence, disabled_optimizations: disabled, mir_profile: profile)
    end
    vm = instance.runtime
    2.times do
      caught = false
      begin
        vm.call_unboxed('raise', [])
      rescue Wardite::UncaughtWasmException => error
        raise 'lost payload' unless error.payload == [42]
        raise 'lost tag' unless error.tag.equal?(instance.tags[0])
        caught = true
      end
      raise 'missing uncaught error' unless caught
      raise 'bad recovery' unless vm.call_unboxed('ok', []) == 42
      %w[null reuse].each do |name|
        trapped = false
        begin
          vm.call_unboxed(name, [])
        rescue Wardite::EvalError => error
          raise 'wrong trap' unless error.message == 'throw_ref null'
          trapped = true
        end
        raise 'stale pooled reference' unless trapped
        raise 'bad trap recovery' unless vm.call_unboxed('ok', []) == 42
      end
    end
  end
end
puts 'M1 API recovery passed'
