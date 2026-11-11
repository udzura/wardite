# frozen_string_literal: true

require "json"
require "wardite"
require "wardite/cli/cli"

module StartupMeasurement
  SECONDS = Hash.new(0.0)

  def self.measure(klass, method_name, phase)
    wrapper = Module.new do
      define_method(method_name) do |*args, **kwargs, &block|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        super(*args, **kwargs, &block)
      ensure
        SECONDS[phase] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end
      private method_name if klass.private_method_defined?(method_name)
    end
    klass.prepend(wrapper)
  end
end

wasm = ARGV.shift || abort("Usage: ruby -Ilib #{$PROGRAM_NAME} RUBY.wasm [--mir-cache DIR]")
efflorescence = Wardite::Efflorescence
StartupMeasurement.measure(Wardite::BinaryLoader.singleton_class, :sections, :decode)
StartupMeasurement.measure(Wardite::Store, :initialize, :store)
StartupMeasurement.measure(efflorescence::Translator, :translate, :translate)
StartupMeasurement.measure(efflorescence::Optimizer, :optimize, :optimize)
StartupMeasurement.measure(efflorescence::RegisterValidation, :validate, :validate)
StartupMeasurement.measure(efflorescence::Lowerer, :compile, :lower)
StartupMeasurement.measure(efflorescence::VM, :call, :execute)
StartupMeasurement.measure(Wardite::Cli::Cli, :new_instance, :load)
if ARGV.include?("--mir-cache")
  require "wardite/efflorescence/mir_cache"
  StartupMeasurement.measure(efflorescence::MIRCache, :read, :cache_read)
  StartupMeasurement.measure(efflorescence::MIRCache, :write, :cache_write)
end

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
Wardite::Cli::Cli.new(["--new-engine", *ARGV, "--", wasm, "--disable-gems", "-e", "puts RUBY_VERSION; puts 6*7"]).run
StartupMeasurement::SECONDS[:total] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
warn JSON.generate(ruby: RUBY_DESCRIPTION, yjit: RubyVM::YJIT.enabled?, seconds: StartupMeasurement::SECONDS)
