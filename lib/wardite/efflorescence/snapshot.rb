# frozen_string_literal: true
# rbs_inline: enabled

require "digest"
require "fileutils"
require "wardite/efflorescence/mir_cache" unless RUBY_ENGINE == "spinel"

module Wardite
  module Efflorescence
    class SavedFrame
      attr_reader :pool_index #: Integer
      attr_reader :pc #: Integer
      attr_reader :return_register #: Integer
      attr_reader :registers #: Array[Integer]
      attr_reader :handlers #: Array[Integer]

      # @rbs pool_index: Integer
      # @rbs pc: Integer
      # @rbs return_register: Integer
      # @rbs registers: Array[Integer]
      # @rbs handlers: Array[Integer]
      def initialize(pool_index, pc, return_register, registers, handlers)
        @pool_index = pool_index
        @pc = pc
        @return_register = return_register
        @registers = registers
        @handlers = handlers
      end
    end

    # Startup snapshot of a WASI command (ADR 0012). The state is saved just
    # before the first WASI call whose result is not fixed by the key, and a
    # later run with the same key resumes from there.
    class Snapshot
      MAGIC = "WARDSNP\0".b
      FORMAT_VERSION = 1
      PAGE_SIZE = 65536
      ZERO_PAGE = ("\0" * PAGE_SIZE).b
      # Their results depend only on values in the key, or are frozen into the
      # snapshot (clocks and random bytes). fd_filestat_get is allowed for
      # stdio only: CRuby probes fds 0-2 before anything else.
      ALLOWED = %i[args_sizes_get args_get environ_sizes_get environ_get fd_prestat_get
        fd_prestat_dir_name fd_fdstat_get clock_res_get clock_time_get random_get].freeze

      attr_reader :path #: String

      # @rbs directory: String
      # @rbs instance: Wardite::Instance
      # @rbs mir_cache: Wardite::Efflorescence::MIRCache
      def initialize(directory, instance, mir_cache)
        wasi = instance.wasi || raise(Wardite::ArgumentError, "snapshot requires WASI")
        @wasi = wasi
        @fds = wasi.fd_table.keys.sort
        @fd_count = wasi.fd_count
        pages = instance.store.memories.map { |memory| memory.current }
        key_data = [FORMAT_VERSION, pages.size, *pages].pack("L<*") + mir_cache.key + wasi.snapshot_identity
        key = Digest::SHA256.digest(key_data)
        @header = MAGIC + [FORMAT_VERSION].pack("L<") + key
        @directory = File.expand_path(directory)
        @path = File.join(@directory, "#{key.unpack1("H*")}.snap")
      end

      # Does this host call end the deterministic prefix of the run?
      # @rbs host: Wardite::Efflorescence::HostFunction
      # @rbs registers: Array[Integer]
      # @rbs sources: Array[Integer]
      # @rbs return: bool
      def checkpoint?(host, registers, sources)
        external = host.external
        return true unless @wasi.equal?(external.target_module)
        name = external.name
        return registers[sources.fetch(0)] > 2 if name == :fd_filestat_get
        !ALLOWED.include?(name)
      end

      # Saving is best effort: any refusal or I/O error leaves the run as is.
      # @rbs instance: Wardite::Instance
      # @rbs frames: Array[Wardite::Efflorescence::Frame]
      # @rbs return: void
      def save(instance, frames)
        started = Time.now.to_f
        return trace("skipped (open descriptors changed)") unless @wasi.fd_table.keys.sort == @fds && @wasi.fd_count == @fd_count
        store = instance.store
        return trace("skipped (multiple memories)") if store.memories.size > 1
        writer = MIRCache::Writer.new
        writer.integers(@fd_count)
        access = StoreAccess.new(store)
        globals = [] #: Array[Integer]
        store.globals.each_with_index do |global, index|
          globals << case global.type
          when :i64 then access.global_get_i64(index)
          when :f32, :f64 then access.global_get_float(index, global.type)
          else access.global_get(index)
          end
        end
        writer.vector(globals, "q<")
        writer.integers(frames.size)
        frames.each do |frame|
          return trace("skipped (pending exception reference)") unless frame.exception_registers.compact.empty?
          writer.integers(frame.pool_index, frame.pc, frame.return_register)
          writer.vector(frame.registers, "q<")
          writer.vector(frame.handlers)
        end
        memory = store.memories[0]
        pages = memory ? memory.current : 0
        used = [] #: Array[Integer]
        if memory
          pages.times { |page| used << page unless memory.read_bytes(page * PAGE_SIZE, PAGE_SIZE) == ZERO_PAGE }
        end
        writer.integers(pages)
        writer.vector(used)
        payload = writer.bytes
        if memory
          return trace("skipped (too large)") if payload.bytesize + used.size * PAGE_SIZE > MIRCache::MAX_BYTES
          used.each { |page| payload << memory.read_bytes(page * PAGE_SIZE, PAGE_SIZE) }
        end
        FileUtils.mkdir_p(@directory)
        MIRCache.publish(@directory, @path, @header, payload)
        trace("saved", started)
      rescue SystemCallError, IOError
        trace("skipped (write failed)")
      end

      # Validate everything before touching the Store, so a rejected file
      # leaves a fresh instance for the normal start.
      # @rbs vm: Wardite::Efflorescence::VM
      # @rbs return: Array[Wardite::Efflorescence::SavedFrame]?
      def restore(vm)
        started = Time.now.to_f
        instance = vm.instance
        store = instance.store
        reader = MIRCache::Reader.new(MIRCache.read_payload(@path, @header))
        raise MIRCache::Invalid unless reader.integer == @wasi.fd_count && store.memories.size <= 1
        globals = reader.vector("q<", 8)
        raise MIRCache::Invalid unless globals.size == store.globals.size
        functions = vm.ir.functions
        frames = [] #: Array[SavedFrame]
        reader.count(12).times do
          pool_index = reader.integer
          pc = reader.integer
          return_register = reader.integer
          registers = reader.vector("q<", 8)
          handlers = reader.vector("l<", 4)
          frames << SavedFrame.new(pool_index, pc, return_register, registers, handlers)
        end
        raise MIRCache::Invalid if frames.empty?
        frames.each_with_index { |frame, index| check_frame(functions, frames, index) }
        memory = store.memories[0]
        pages = reader.integer
        used = reader.vector("l<", 4)
        current = memory ? memory.current : 0
        raise MIRCache::Invalid unless (memory || pages == 0) && pages >= current
        raise MIRCache::Invalid unless used.all? { |page| page >= 0 && page < pages }
        contents = reader.bytes(used.size * PAGE_SIZE)
        reader.finish

        if memory
          raise MIRCache::Invalid if pages > current && memory.grow(pages - current) < 0
          used_pages = Array.new(pages, false)
          used.each_with_index do |page, i|
            used_pages[page] = true
            memory.write_bytes(page * PAGE_SIZE, contents.byteslice(i * PAGE_SIZE, PAGE_SIZE) || raise(MIRCache::Invalid))
          end
          used_pages.each_with_index { |nonzero, page| memory.write_bytes(page * PAGE_SIZE, ZERO_PAGE) unless nonzero }
        end
        access = StoreAccess.new(store)
        store.globals.each_with_index do |global, index|
          value = globals.fetch(index)
          case global.type
          when :i64 then access.global_set_i64(index, value)
          when :f32, :f64 then access.global_set_float(index, global.type, value)
          else access.global_set(index, value)
          end
        end
        trace("restored", started)
        frames
      rescue SystemCallError, IOError, MIRCache::Invalid
        trace("miss")
        nil
      end

      private

      # The top frame resumes at its host call. Callers resume after the call
      # that created the frame above them, which writes its return register.
      # @rbs functions: Array[Wardite::Efflorescence::Function]
      # @rbs frames: Array[Wardite::Efflorescence::SavedFrame]
      # @rbs index: Integer
      # @rbs return: void
      def check_frame(functions, frames, index)
        frame = frames.fetch(index)
        function = functions[frame.pool_index] || raise(MIRCache::Invalid)
        code = function.bytecode
        pc = frame.pc
        raise MIRCache::Invalid unless pc >= 0 && pc < code.size && pc % Lowerer::WIDTH == 0
        raise MIRCache::Invalid unless frame.registers.size == function.initial_registers.size
        raise MIRCache::Invalid unless frame.handlers.all? { |id| id >= 0 && id < function.flat_handlers.size }
        if index == frames.size - 1
          opcode = code.fetch(pc)
          raise MIRCache::Invalid unless opcode == Opcode::CALL_HOST || opcode == Opcode::CALL_INDIRECT
        else
          raise MIRCache::Invalid unless pc >= Lowerer::WIDTH
          opcode = code.fetch(pc - Lowerer::WIDTH)
          raise MIRCache::Invalid unless opcode == Opcode::CALL || opcode == Opcode::CALL_INDIRECT
        end
        destination = frame.return_register
        if index == 0
          raise MIRCache::Invalid unless destination == -1
        else
          raise MIRCache::Invalid unless destination >= -1 && destination < frames.fetch(index - 1).registers.size
        end
      end

      # @rbs message: String
      # @rbs started: Float
      # @rbs return: void
      def trace(message, started = 0.0)
        return unless ENV["WARDITE_TRACE"]
        elapsed = started > 0 ? " (#{(Time.now.to_f - started).round(3)}s)" : ""
        $stderr.puts "snapshot #{message}: #{@path}#{elapsed}"
      end
    end
  end
end
