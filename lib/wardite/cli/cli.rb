# rbs_inline: enabled
require "optparse"

module Wardite
  module Cli
    class Cli
      # @rbs @args: Array[String]

      attr_reader :invoke  #: String?
      attr_reader :mapdir  #: String?
      attr_reader :file    #: String
      attr_reader :memsize #: Integer
      attr_reader :wasi    #: bool
      attr_reader :yjit    #: bool
      attr_reader :new_engine #: bool
      attr_reader :disabled_optimizations #: Array[Symbol]
      attr_reader :mir_dump #: bool
      attr_reader :mir_profile #: bool

      attr_reader :profile_file_path #: String?

      # @rbs args: Array[String]
      # @rbs return: void
      def initialize(args)
        @invoke = @mapdir = nil
        @wasi = RUBY_ENGINE != "spinel"
        @yjit = false
        @new_engine = false
        @disabled_optimizations = []
        @mir_dump = false
        @mir_profile = false
        @memsize = 1
        options = OptionParser.new do |opts|
          opts.version = Wardite::VERSION
          opts.on("--invoke [fnname]", "Invoke the function") { |v|
            @invoke = v
          }
          opts.on("--mapdir [dirs]", "Map the directory") { |v|
            @mapdir = v
          }
          opts.on("--memsize [size_in_bytes]", "Initial memory size") { |v|
            @memsize = (v.to_i / (64 * 1024).to_f).ceil.to_i
          }
          opts.on("--no-wasi", "Disable WASI feature") {|_v|
            @wasi = false
          }
          opts.on("--new-engine", "Use the Efflorescence register VM (i32 subset)") {|_v|
            @new_engine = true
          }
          opts.on("--mir-disable NAME", "Disable copy, immediate, branch, superinstruction, inline, frames, or all (repeatable)") {|v|
            @disabled_optimizations << v.to_sym
          }
          opts.on("--mir-dump", "Print semantic and optimized MIR") { @mir_dump = true }
          opts.on("--mir-profile", "Instrument MIR execution (do not use for timing)") { @mir_profile = true }
          opts.on("--yjit", "Enable yjit if available; setting WARDITE_YJIT_ON=1 has the same effect") {|_v|
            @yjit = true
          }
          opts.on("--out-profile [file]", "Enable Vernier profiling and save to the file") {|v|
            @profile_file_path = v
          }
          opts.on("FILE.wasm") { }
        end
        options.parse!(args)
        if !new_engine && (!disabled_optimizations.empty? || mir_dump || mir_profile)
          raise "MIR options require --new-engine"
        end
        @file = args[0] || raise("require file argument")
        @args = (args[1..-1] || [])
        @args.unshift if @args[0] == '--'

        if RUBY_ENGINE == "spinel"
          warn "Warning: YJIT is not available in Spinel builds" if yjit || ENV["WARDITE_YJIT_ON"] == "1"
        else
          if (yjit || ENV["WARDITE_YJIT_ON"] == "1") && (defined? RubyVM::YJIT)
            RubyVM::YJIT.enable
          end

          if (yjit || ENV["WARDITE_YJIT_ON"] == "1") && !defined?(RubyVM::YJIT)
            warn "Warning: --yjit option is specified, but not available in this Ruby build"
          end
        end
      end

      # @rbs return: Array[Integer | Float]
      def args
        @args.map do |a|
          if a.include? "."
            a.to_f
          else
            a.to_i
          end
        end
      end

      # @rbs return: ::Wardite::Instance
      def new_instance
        ins = File.open(file, "rb") do |f|
          Wardite::BinaryLoader.load_from_buffer(f, enable_wasi: wasi, engine: new_engine ? :efflorescence : :stack,
            disabled_optimizations: disabled_optimizations, mir_profile: mir_profile)
        end
        if memsize > 1
          ins.store.memories[0].grow(memsize)
        end
        ins
      end

      # @rbs return: void
      def run
        if RUBY_ENGINE == "spinel"
          __run
        else
          if profile_file_path
            require "vernier"
            $stderr.puts "Activated Vernier profiling"
            Vernier.profile(out: profile_file_path) do
              __run
            end
          else
            __run
          end
        end
      end

      # @rbs return: void
      def __run
        if invoke
          invoke_function
        else
          if wasi
            invoke_wasi
            return
          end
          raise("requires function name to invoke")
        end
      end

      # @rbs return: void
      def invoke_function
        unless invoke
          raise "--invoke not set"
        end
        instance = new_instance
        ret = instance.runtime.call(invoke, args)
        runtime = instance.runtime
        if runtime.is_a?(Wardite::Efflorescence::VM)
          $stderr.puts runtime.dump_mir if mir_dump
          $stderr.puts runtime.metrics.report if mir_profile
        end
        $stderr.puts "return value: #{ret.inspect}"
      end

      # @rbs return: void
      def invoke_wasi
        instance = new_instance #: ::Wardite::Instance
        wasi_env = instance.wasi
        if wasi_env
          wasi_env.argv = ["wardite"] + @args
          destination = mount_dst
          source = mount_src
          if mapdir && destination && source
            # TODO: support multiple mapdir
            wasi_env.mapdir[destination] = source
            wasi_env.set_preopened_dir(destination, source)
          end
        end

        if defined? Bundler
          Bundler.with_original_env do
            instance.runtime.call(:_start, [])
          end
        else
          instance.runtime.call(:_start, [])
        end
      end

      # @rbs return: String?
      def mount_src
        mapdir&.split(":")&.first
      end

      # @rbs return: String?
      def mount_dst
        m = mapdir&.split(":")
        if m
          m.size == 2 ? m[1] : m[0]
        end
      end
    end
  end
end
