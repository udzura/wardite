# rbs_inline: enabled
require "optparse"

module Wardite
  module Cli
    # Keep the summary accumulator's type consistent in native builds.
    class SpinelOptions < OptionParser
      # @rbs return: String
      def help
        lines = [] #: Array[String]
        summarize(lines)
        "#{banner}".sub(/\n?\z/, "\n") + lines.join
      end
    end

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
      attr_reader :mir_cache #: String?
      attr_reader :snapshot #: String?

      attr_reader :profile_file_path #: String?

      # @rbs args: Array[String]
      # @rbs return: void
      def initialize(args)
        @invoke = @mapdir = nil
        @wasi = true
        @yjit = false
        @new_engine = false
        @disabled_optimizations = []
        @mir_dump = false
        @mir_profile = false
        @mir_cache = nil
        @mir_cache_verify = :checksum
        @mir_cache_eager = false
        @snapshot = nil
        @memsize = 1
        parser = RUBY_ENGINE == "spinel" ? SpinelOptions : OptionParser
        options = parser.new do |opts|
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
          opts.on("--new-engine", "Use the Efflorescence register VM") {|_v|
            @new_engine = true
          }
          opts.on("--mir-disable NAME", "Disable copy, immediate, branch, superinstruction, inline, frames, or all (repeatable)") {|v|
            @disabled_optimizations << v.to_sym
          }
          opts.on("--mir-dump", "Print semantic and optimized MIR") { @mir_dump = true }
          opts.on("--mir-profile", "Instrument MIR execution (do not use for timing)") { @mir_profile = true }
          opts.on("--mir-cache DIR", "Reuse MIR2 in a local directory") { |dir| @mir_cache = dir }
          opts.on("--mir-cache-eager", "Restore and check every cached MIR2 function at load time") { @mir_cache_eager = true }
          opts.on("--mir-cache-verify MODE", "Verify the MIR2 cache with checksum (default) or sha256") do |mode|
            unless mode == "checksum" || mode == "sha256"
              raise Wardite::ArgumentError, "--mir-cache-verify expects checksum or sha256"
            end
            @mir_cache_verify = mode.to_sym
          end
          opts.on("--snapshot DIR", "Resume WASI startup from a local snapshot (needs --mir-cache; fixes clocks and random bytes read before it)") { |dir| @snapshot = dir }
          opts.on("--yjit", "Enable yjit if available; setting WARDITE_YJIT_ON=1 has the same effect") {|_v|
            @yjit = true
          }
          opts.on("--out-profile [file]", "Enable Vernier profiling and save to the file") {|v|
            @profile_file_path = v
          }
          opts.on("FILE.wasm") { }
        end
        options.parse!(args)
        if !new_engine && (!disabled_optimizations.empty? || mir_dump || mir_profile || mir_cache)
          raise "MIR options require --new-engine"
        end
        if snapshot && (!new_engine || !mir_cache || mir_dump || mir_profile)
          raise "--snapshot requires --new-engine and --mir-cache, without --mir-dump or --mir-profile"
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
            disabled_optimizations: disabled_optimizations, mir_profile: mir_profile,
            mir_cache: mir_dump ? nil : mir_cache, mir_cache_verify: @mir_cache_verify, mir_cache_eager: @mir_cache_eager)
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
            start_wasi(instance)
          end
        else
          start_wasi(instance)
        end
      end

      # The snapshot key reads the environment, so build it where _start runs.
      # @rbs instance: ::Wardite::Instance
      # @rbs return: void
      def start_wasi(instance)
        runtime = instance.runtime
        directory = snapshot
        if directory && runtime.is_a?(Wardite::Efflorescence::VM)
          cache = runtime.mir_cache
          if cache && instance.wasi && !instance.start_section
            require "wardite/efflorescence/snapshot" unless RUBY_ENGINE == "spinel"
            recorder = Wardite::Efflorescence::Snapshot.new(directory, instance, cache)
            frames = runtime.mir_cache_hit ? recorder.restore(runtime) : nil
            if frames
              runtime.resume(frames)
              return
            end
            runtime.snapshot = recorder
          end
        end
        runtime.call(:_start, [])
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
