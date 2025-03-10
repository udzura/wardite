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

      # @rbs args: Array[String]
      # @rbs return: void
      def initialize(args)
        @invoke = @mapdir = nil
        @wasi = true # default to true
        @memsize = 1
        options = OptionParser.new do |opts|
          opts.on("--invoke [fnname]", "Invoke the function") { |v|
            @invoke = v
          }
          opts.on("--mapdir [dest[:src]]", "Map the directory") { |v|
            @mapdir = v
          }
          opts.on("--memsize [size_in_bytes]", "Initial memory size") { |v|
            @memsize = (v.to_i / (64 * 1024).to_f).ceil.to_i
          }
          opts.on("--no-wasi", "Disable WASI feature") {|_v|
            @wasi = false
          }
          opts.on("FILE.wasm") { }
        end
        options.parse!(args)
        @file = args[0] || raise("require file argument")
        @args = (args[1..-1] || [])
        @args.unshift if @args[0] == '--'
      end

      # @rbs return: Array[Integer | Float]
      # @rbs %a{pure}
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
        f = File.open(file)
        ins = Wardite::BinaryLoader::load_from_buffer(f, enable_wasi: wasi);
        if memsize > 1
          ins.store.memories[0].grow(memsize)
        end
        ins
      end

      # @rbs return: void
      def run
        if invoke
          invoke_function
        else
          invoke_wasi if wasi
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
        $stderr.puts "return value: #{ret.inspect}"
      end

      # @rbs return: void
      def invoke_wasi
        instance = new_instance #: ::Wardite::Instance
        unless instance.wasi
          raise "WASI not activated"
        end
        instance.wasi.argv = ["wardite"] + @args
        if mapdir && mount_dst && mount_src
          # TODO: support multiple mapdir
          instance.wasi.mapdir[mount_dst] = mount_src
        end

        if defined? Bundler
          Bundler.with_original_env do
            instance.runtime._start
          end
        else
          instance.runtime._start
        end              
      end

      # @rbs return: String?
      # @rbs %a{pure}
      def mount_src
        mapdir&.split(":")&.first
      end

      # @rbs return: String?
      # @rbs %a{pure}
      def mount_dst
        m = mapdir&.split(":")
        if m
          m.size == 2 ? m[1] : m[0]
        end
      end
    end
  end
end