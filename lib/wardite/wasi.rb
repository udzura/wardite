# rbs_inline: enabled

require "wardite/wasm_module"
require "wardite/wasi/consts"
require "wardite/wasi/preopens"
require "wardite/wasi/dirent_cache"
require "securerandom"
if RUBY_ENGINE == "spinel"
  require "wardite/wasi/spinel"
else
  require "fcntl"
end

module Wardite
  class WasiSnapshotPreview1
    include ValueHelper
    include WasmModule

    # Preview 1 imports return errno (i32), except for proc_exit.
    IMPORT_PARAMETERS = {
      args_get: %i[i32 i32],
      args_sizes_get: %i[i32 i32],
      environ_get: %i[i32 i32],
      environ_sizes_get: %i[i32 i32],
      clock_res_get: %i[i32 i32],
      clock_time_get: %i[i32 i64 i32],
      fd_advise: %i[i32 i64 i64 i32],
      fd_close: %i[i32],
      fd_datasync: %i[i32],
      fd_fdstat_get: %i[i32 i32],
      fd_fdstat_set_flags: %i[i32 i32],
      fd_filestat_get: %i[i32 i32],
      fd_filestat_set_size: %i[i32 i64],
      fd_pread: %i[i32 i32 i32 i64 i32],
      fd_prestat_get: %i[i32 i32],
      fd_prestat_dir_name: %i[i32 i32 i32],
      fd_pwrite: %i[i32 i32 i32 i64 i32],
      fd_read: %i[i32 i32 i32 i32],
      fd_readdir: %i[i32 i32 i32 i64 i32],
      fd_renumber: %i[i32 i32],
      fd_seek: %i[i32 i64 i32 i32],
      fd_sync: %i[i32],
      fd_tell: %i[i32 i32],
      fd_write: %i[i32 i32 i32 i32],
      path_create_directory: %i[i32 i32 i32],
      path_filestat_get: %i[i32 i32 i32 i32 i32],
      path_filestat_set_times: %i[i32 i32 i32 i32 i64 i64 i32],
      path_link: %i[i32 i32 i32 i32 i32 i32 i32],
      path_open: %i[i32 i32 i32 i32 i32 i64 i64 i32 i32],
      path_readlink: %i[i32 i32 i32 i32 i32 i32],
      path_remove_directory: %i[i32 i32 i32],
      path_rename: %i[i32 i32 i32 i32 i32 i32],
      path_symlink: %i[i32 i32 i32 i32 i32],
      path_unlink_file: %i[i32 i32 i32],
      poll_oneoff: %i[i32 i32 i32 i32],
      proc_exit: %i[i32],
      random_get: %i[i32 i32],
    }.transform_values(&:freeze).freeze #: Hash[Symbol, Array[Symbol]]

    # @rbs name: Symbol
    # @rbs parameters: Array[Symbol]
    # @rbs results: Array[Symbol]
    # @rbs return: void
    def validate_import(name, parameters, results)
      expected = IMPORT_PARAMETERS[name]
      raise Wardite::LoadError, "unknown WASI import #{name}" unless expected
      unless parameters == expected && results == (name == :proc_exit ? [] : [:i32])
        raise Wardite::LoadError, "invalid WASI signature for #{name}"
      end
    end

    # @rbs name: Symbol
    # @rbs return: _WasmCallable
    def callable(name)
      if RUBY_ENGINE == "spinel"
        raise Wardite::LoadError, "unknown WASI import #{name}" unless IMPORT_PARAMETERS[name]
        ->(store, args) { dispatch_native_import(name, store, args) }
      else
        public_method(name)
      end
    end

    attr_accessor :fd_table #: Hash[Integer, (IO|File|::Wardite::Wasi::PreopenedDir)]
    attr_accessor :fd_count #: Integer
    attr_accessor :argv #: Array[String]
    attr_accessor :mapdir #: Hash[String, String]
    attr_accessor :dirent_cache #: Hash[Integer, ::Wardite::Wasi::DirentCache]

    # @rbs argv: Array[String]
    # @rbs mapdir: Hash[String, String]
    # @rbs return: void
    def initialize(argv: [], mapdir: {})
      @fd_table = {
        0 => STDIN,
        1 => STDOUT,
        2 => STDERR,
      }
      @fd_count = 3
      @argv = argv
      @mapdir = mapdir

      @dirent_cache = {}
    end

    # @rbs file: IO|File|::Wardite::Wasi::PreopenedDir
    # @rbs return: Integer
    def set_fd(file)
      fd = @fd_count
      @fd_table[fd] = file
      @fd_count += 1
      fd
    end

    # @rbs path: String
    # @rbs guest_path: String
    # @rbs return: void
    def set_preopened_dir(path, guest_path)
      fd = @fd_count
      set_fd(::Wardite::Wasi::PreopenedDir.new(path, guest_path, fd))
    end

    # @rbs orig_path: String
    # @rbs return: String
    def resolv_path(orig_path)
      @mapdir.each do |k, v|
        if orig_path.start_with?(k)
          return v + orig_path[k.size..-1].to_s
        end
      end

      return orig_path
    end

    # @rbs atfd: Integer
    # @rbs target: String
    # @rbs return: String
    def get_path_at(atfd, target)
      target = resolv_path(target)

      at = @fd_table[atfd]
      pwd = case at
            when Wasi::PreopenedDir
              at.guest_path
            when File
              Dir.fchdir(at.fileno) do
                Dir.pwd
              end
            else
              raise ArgumentError, "invalid fd: #{atfd}"
            end

      ret = File.expand_path(target, pwd)
      ret
    end

    # @rbs dirflags: Integer
    # @rbs oflags: Integer
    # @rbs fdflags: Integer
    # @rbs rights: Integer
    def interpret_open_flags(dirflags, oflags, fdflags, rights)
      open_flags = 0
      if dirflags & Wasi::LOOKUP_SYMLINK_FOLLOW == 0
        open_flags |= File::NOFOLLOW
      end
      if oflags & Wasi::O_DIRECTORY != 0
        # open_flags |= File::DIRECTORY
        $stderr.puts "O_DIRECTORY is not supported, ignore" if ENV["WARDITE_TRACE"]
      elsif oflags & Wasi::O_EXCL != 0
        open_flags |= File::EXCL
      end

      default_mode = File::RDONLY
      if oflags & Wasi::O_TRUNC != 0
        open_flags |= File::TRUNC
        default_mode = File::RDWR
      end
      if oflags & Wasi::O_CREAT != 0
        open_flags |= File::CREAT
        default_mode = File::RDWR
      end
      if fdflags & Wasi::FD_NONBLOCK != 0
        open_flags |= File::NONBLOCK
      end
      if fdflags & Wasi::FD_APPEND != 0
        open_flags |= File::APPEND
        default_mode = File::RDWR
      end
      if fdflags & Wasi::FD_DSYNC != 0
        open_flags |= File::DSYNC
      end
      if fdflags & (Wasi::FD_SYNC | Wasi::FD_RSYNC) != 0
        open_flags |= File::SYNC
      end

      r = Wasi::RIGHT_FD_READ
      w = Wasi::RIGHT_FD_WRITE
      rw = r | w
      case
      when (rights & rw) == rw
        open_flags |= File::RDWR
      when (rights & w) == w
        open_flags |= File::WRONLY
      when (rights & r) == r
        open_flags |= File::RDONLY
      else
        open_flags |= default_mode
      end

      open_flags
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def args_get(store, args)
      write_guest_strings(store, args, @argv.map { |arg| (arg + "\0").b })
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def args_sizes_get(store, args)
      write_guest_sizes(store, args, @argv.size, @argv.sum { |arg| arg.bytesize + 1 })
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def environ_sizes_get(store, args)
      entries = environment_entries
      write_guest_sizes(store, args, entries.size, entries.sum(&:bytesize))
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def environ_get(store, args)
      write_guest_strings(store, args, environment_entries)
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Integer
    def clock_res_get(store, args)
      write_clock(store, args.fetch(0).value.to_i, args.fetch(1).value.to_i, resolution: true)
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Integer
    def clock_time_get(store, args)
      write_clock(store, args.fetch(0).value.to_i, args.fetch(2).value.to_i, resolution: false)
    end

    # These imports can be linked, but their operations are not implemented.
    # @rbs (Store, Array[wasmValue]) -> Integer
    def fd_advise(_store, _args)
      Wasi::ENOSYS
    end
    alias fd_datasync fd_advise
    alias fd_fdstat_set_flags fd_advise
    alias fd_filestat_set_size fd_advise
    alias fd_pread fd_advise
    alias fd_pwrite fd_advise
    alias fd_renumber fd_advise
    alias fd_seek fd_advise
    alias fd_sync fd_advise
    alias poll_oneoff fd_advise

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def path_create_directory(store, args)
      fd = args[0].value.to_i
      path = args[1].value.to_i
      path_len = args[2].value.to_i
      path_str = guest_path(store, path, path_len)
      return Wasi::EFAULT unless path_str

      target = get_path_at(fd, path_str)
      Dir.mkdir(target, 0700)
      0
      # TODO; rescue EBADF, ENOTDIR
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def path_filestat_get(store, args)
      fd = args[0].value.to_i
      flags = args[1].value.to_i
      path = args[2].value.to_i
      path_len = args[3].value.to_i
      result = args[4].value.to_i
      return Wasi::EINVAL unless (flags & ~Wasi::LOOKUP_SYMLINK_FOLLOW) == 0

      memory = store.memories[0]
      return Wasi::EFAULT unless memory && memory.range?(path, path_len) && memory.range?(result, 64)
      target = directory_path(fd, memory.read_bytes(path, path_len).to_s)
      return target if target.is_a?(Integer)

      stat = (flags & Wasi::LOOKUP_SYMLINK_FOLLOW) != 0 ? File.stat(target) : File.lstat(target)
      memory.write_bytes(result, filestat_bytes(stat))
      0
    rescue SystemCallError => error
      filesystem_errno(error)
    rescue IOError
      Wasi::EBADF
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def path_filestat_set_times(store, args)
      fd = args[0].value.to_i
      # TODO: flags support
      _flags = args[1].value.to_i
      path = args[2].value.to_i
      path_len = args[3].value.to_i
      atim = args[4].value.to_i # nanoseconds
      mtim = args[5].value.to_i # nanoseconds
      guest_name = guest_path(store, path, path_len)
      return Wasi::EFAULT unless guest_name
      target = get_path_at(fd, guest_name)

      atime = Time.at(atim.to_f / 1_000_000_000)
      mtime = Time.at(mtim.to_f / 1_000_000_000)
      File.utime(atime, mtime, target)
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def path_link(store, args)
      old_fd = args[0].value.to_i
      old_path = args[1].value.to_i
      old_path_len = args[2].value.to_i
      old_guest_name = guest_path(store, old_path, old_path_len)
      return Wasi::EFAULT unless old_guest_name
      old_name = get_path_at(old_fd, old_guest_name)

      new_fd = args[3].value.to_i
      new_path = args[4].value.to_i
      new_path_len = args[5].value.to_i
      guest_name = guest_path(store, new_path, new_path_len)
      return Wasi::EFAULT unless guest_name
      new_name = get_path_at(new_fd, guest_name)

      File.link(old_name, new_name)
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def path_open(store, args)
      dirfd = args[0].value.to_i
      dirflags = args[1].value.to_i
      path = args[2].value.to_i
      path_len = args[3].value.to_i
      oflags = args[4].value.to_i
      fs_rights_base = args[5].value.to_i
      _fs_rights_inheriting = args[6].value.to_i
      fs_flags = args[7].value.to_i
      fd_off = args[8].value.to_i

      memory = store.memories[0]
      return Wasi::EFAULT unless memory && memory.range?(path, path_len) && memory.range?(fd_off, 4)
      path_name = directory_path(dirfd, memory.read_bytes(path, path_len).to_s)
      return path_name if path_name.is_a?(Integer)
      open_flags = interpret_open_flags(dirflags, oflags, fs_flags, fs_rights_base)
      is_dir = (oflags & Wasi::O_DIRECTORY) != 0
      if is_dir && (oflags & Wasi::O_CREAT) != 0
        return Wasi::EINVAL
      end

      file = File.open(path_name, open_flags, 0600)
      fd = set_fd file

      memory.write_bytes(fd_off, [fd].pack("V"))
      0
    rescue SystemCallError => error
      filesystem_errno(error)
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def path_readlink(store, args)
      fd = args[0].value.to_i
      path = args[1].value.to_i
      path_len = args[2].value.to_i
      buf = args[3].value.to_i
      buf_len = args[4].value.to_i
      result_buf = args[5].value.to_i

      return Wasi::EINVAL if buf_len <= 0 || path_len <= 0
      memory = store.memories[0]
      return Wasi::EFAULT unless memory && memory.range?(path, path_len) &&
        memory.range?(buf, buf_len) && memory.range?(result_buf, 4)
      target = directory_path(fd, memory.read_bytes(path, path_len).to_s)
      return target if target.is_a?(Integer)

      link_target = File.readlink(target).b
      return Wasi::ENAMETOOLONG if link_target.bytesize > buf_len

      memory.write_bytes(buf, link_target)
      memory.write_bytes(result_buf, [link_target.bytesize].pack("V"))
      0
    rescue SystemCallError => error
      filesystem_errno(error)
    rescue IOError
      Wasi::EBADF
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def path_remove_directory(store, args)
      fd = args[0].value.to_i
      path = args[1].value.to_i
      path_len = args[2].value.to_i
      path_str = guest_path(store, path, path_len)
      return Wasi::EFAULT unless path_str
      target = get_path_at(fd, path_str)

      Dir.rmdir(target)
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def path_rename(store, args)
      fd = args[0].value.to_i
      old_path = args[1].value.to_i
      old_path_len = args[2].value.to_i

      new_fd = args[3].value.to_i
      new_path = args[4].value.to_i
      new_path_len = args[5].value.to_i

      guest_name = guest_path(store, old_path, old_path_len)
      return Wasi::EFAULT unless guest_name
      old_target = get_path_at(fd, guest_name)
      guest_name = guest_path(store, new_path, new_path_len)
      return Wasi::EFAULT unless guest_name
      new_target = get_path_at(new_fd, guest_name)

      File.rename(old_target, new_target)
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def path_symlink(store, args)
      old_path = args[0].value.to_i
      old_path_len = args[1].value.to_i
      old_name = guest_path(store, old_path, old_path_len)
      return Wasi::EFAULT unless old_name

      fd = args[2].value.to_i
      new_path = args[3].value.to_i
      new_path_len = args[4].value.to_i
      guest_name = guest_path(store, new_path, new_path_len)
      return Wasi::EFAULT unless guest_name
      new_name = get_path_at(fd, guest_name)

      File.symlink(old_name, new_name)
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def path_unlink_file(store, args)
      fd = args[0].value.to_i
      path = args[1].value.to_i
      path_len = args[2].value.to_i
      path_str = guest_path(store, path, path_len)
      return Wasi::EFAULT unless path_str
      target = get_path_at(fd, path_str)

      File.unlink(target)
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def fd_prestat_get(store, args)
      fd = args[0].value.to_i
      prestat_offset = args[1].value.to_i
      if fd >= fd_count
        return Wasi::EBADF
      end
      file = @fd_table[fd]
      if !file.is_a?(Wasi::PreopenedDir)
        return Wasi::EBADF
      end
      memory = store.memories[0]
      return Wasi::EFAULT unless memory && memory.range?(prestat_offset, 8)
      # Zero-value 8-bit tag, and 3-byte zero-value padding.
      memory.write_bytes(prestat_offset, [0, file.path.bytesize].pack("V2"))
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def fd_prestat_dir_name(store, args)
      fd = args[0].value.to_i
      path = args[1].value.to_i
      path_len = args[2].value.to_i
      if fd >= fd_count
        return Wasi::EBADF
      end
      file = @fd_table[fd]
      if !file.is_a?(Wasi::PreopenedDir)
        return Wasi::EBADF
      end
      name = file.path.b
      return Wasi::ENAMETOOLONG if name.bytesize > path_len

      memory = store.memories[0]
      return Wasi::EFAULT unless memory && memory.range?(path, path_len)
      memory.write_bytes(path, name + "\0" * (path_len - name.bytesize))
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def fd_write(store, args)
      fd_write_i32(store, args.fetch(0).value.to_i, args.fetch(1).value.to_i,
        args.fetch(2).value.to_i, args.fetch(3).value.to_i)
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def fd_read(store, args)
      file = @fd_table[args.fetch(0).value.to_i]
      return Wasi::EBADF if !file || file.is_a?(Wasi::PreopenedDir)
      iovs = args.fetch(1).value.to_i
      count = args.fetch(2).value.to_i
      result = args.fetch(3).value.to_i
      memory = store.memories[0]
      return Wasi::EFAULT unless memory && memory.range?(result, 4) && memory.range?(iovs, count * 8)

      ranges = [] #: Array[Array[Integer]]
      total = 0
      count.times do |index|
        offset = iovs + index * 8
        start = memory.read_u32(offset)
        length = memory.read_u32(offset + 4)
        return Wasi::EFAULT unless memory.range?(start, length)
        total += length
        return Wasi::EOVERFLOW if total > 0xffffffff
        ranges << [start, length]
      end

      nread = 0
      ranges.each do |range|
        start = range.fetch(0)
        length = range.fetch(1)
        buf = file.read(length)
        break unless buf
        memory.write_bytes(start, buf)
        nread += buf.bytesize
        break if buf.bytesize < length
      end
      memory.write_bytes(result, [nread].pack("V"))
      0
    rescue SystemCallError => error
      filesystem_errno(error)
    rescue IOError
      Wasi::EBADF
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def fd_fdstat_get(store, args)
      file = @fd_table[args.fetch(0).value.to_i]
      return Wasi::EBADF unless file
      offset = args.fetch(1).value.to_i
      memory = store.memories[0]
      return Wasi::EFAULT unless memory && memory.range?(offset, 24)

      kind = fd_kind(file)
      return Wasi::EBADF unless kind
      ftype, fdflags = kind

      fs_right_base = 0
      fs_right_inheriting = 0

      case ftype
      when Wasi::FILETYPE_DIRECTORY
        fs_right_base = Wasi::RIGHT_DIR_RIGHT_BASE
        fs_right_inheriting = Wasi::RIGHT_FILE_RIGHT_BASE | Wasi::RIGHT_DIR_RIGHT_BASE
      when Wasi::FILETYPE_CHARACTER_DEVICE
        fs_right_base = Wasi::RIGHT_FILE_RIGHT_BASE & \
          (~Wasi::RIGHT_FD_SEEK) & (~Wasi::RIGHT_FD_TELL)
      else
        fs_right_base = Wasi::RIGHT_FILE_RIGHT_BASE
      end

      memory.write_bytes(offset, [ftype, fdflags, fs_right_base, fs_right_inheriting].pack("CxS<x4Q<2"))
      0
    rescue SystemCallError => error
      filesystem_errno(error)
    rescue IOError
      Wasi::EBADF
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def fd_filestat_get(store, args)
      file = @fd_table[args[0].value.to_i]
      return Wasi::EBADF unless file && !file.is_a?(Wasi::PreopenedDir)
      offset = args[1].value.to_i
      memory = store.memories[0]
      return Wasi::EFAULT unless memory && memory.range?(offset, 64)

      memory.write_bytes(offset, filestat_bytes(file.stat))
      0
    rescue SystemCallError => error
      filesystem_errno(error)
    rescue IOError
      Wasi::EBADF
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def fd_readdir(store, args)
      fd = args[0].value.to_i
      buf = args[1].value.to_i
      buf_len = args[2].value.to_i
      cookie = args[3].value.to_i
      result_buf_used = args[4].value.to_i

      if buf_len < 24 # when smaller than Dirent header size: Q! Q! I! I!
        return Wasi::EINVAL
      end

      memory = store.memories[0]
      return Wasi::EFAULT unless memory && memory.range?(buf, buf_len) && memory.range?(result_buf_used, 4)

      if dirent_cache[fd]&.eof
        dirent_cache.delete(fd)
      end
      dir = @fd_table[fd]
      if dir.is_a?(Wasi::PreopenedDir) || (dir.is_a?(File) && dir.stat.ftype == "directory")
        dirent_cache[fd] ||= Wasi::DirentCache.new(dir.path)
      else
        return Wasi::EBADF
      end

      dirent = dirent_cache.fetch(fd)
      bindata, is_truncated = dirent.fetch_entries_binary(buf_len, cookie)

      bufused = bindata.bytesize
      # bufused == buf_len means more dirents exist
      if is_truncated
        bufused = buf_len
        bindata += "\0" * (buf_len - bindata.bytesize)
      else
        dirent.eof = true
      end

      memory.write_bytes(buf, bindata)
      memory.write_bytes(result_buf_used, [bufused].pack("V"))
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    def fd_tell(store, args)
      fd = args[0].value.to_i
      result_buf = args[1].value.to_i
      if fd >= fd_count
        return Wasi::EBADF
      end
      file = @fd_table[fd]
      if !file || file.is_a?(Wasi::PreopenedDir)
        return Wasi::EBADF
      end

      memory = store.memories[0]
      return Wasi::EFAULT unless memory && memory.range?(result_buf, 8)
      memory.write_bytes(result_buf, [file.tell].pack("Q<"))
      0
    rescue SystemCallError => error
      filesystem_errno(error)
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def fd_close(store, args)
      fd = args[0].value.to_i
      if fd >= fd_count
        return Wasi::EBADF
      end
      file = @fd_table[fd]
      if !file
        return Wasi::EBADF
      end
      if file.is_a?(Wasi::PreopenedDir)
        # do nothing for preopened dir...?
        $stderr.puts "close preopened dir?: #{file.guest_path}"
        @fd_table.delete(fd)
        return 0
      end
      file.close
      @fd_table.delete(fd)
      0
    rescue SystemCallError => error
      filesystem_errno(error)
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def proc_exit(store, args)
      exit_code = args[0].value
      exit(exit_code)
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def random_get(store, args)
      buf = args[0].value.to_i
      buflen = args[1].value.to_i
      memory = store.memories[0]
      return Wasi::EFAULT unless memory && memory.range?(buf, buflen)
      memory.write_bytes(buf, SecureRandom.random_bytes(buflen))
      0
    end

    # Everything an allowed call before a startup snapshot can observe:
    # arguments, environment, and the kind of every open descriptor.
    # @rbs return: String
    def snapshot_identity
      identity = "".b
      entries = argv.map { |arg| "#{arg}\0".b } + ["\0".b] + environment_entries
      entries.each { |entry| identity << [entry.bytesize].pack("L<") << entry }
      fd_table.keys.sort.each do |fd|
        file = fd_table[fd]
        next unless file
        if file.is_a?(Wasi::PreopenedDir)
          identity << [fd, -1, -1].pack("l<3") << "#{file.path}\0#{file.guest_path}\0".b
        else
          kind = fd_kind(file) || [-1, -1]
          identity << [fd, kind[0], kind[1]].pack("l<3")
        end
      end
      identity
    end

    # @rbs file: IO|File|::Wardite::Wasi::PreopenedDir
    # @rbs return: [Integer, Integer]?
    def fd_kind(file)
      return [Wasi.to_ftype(File.stat(file.guest_path).ftype), 0] if file.is_a?(Wasi::PreopenedDir)
      flags = if RUBY_ENGINE == "spinel"
        Wasi::Native.wardite_wasi_getfl(file.fileno)
      else
        file.fcntl(Fcntl::F_GETFL, 0)
      end
      return nil if flags < 0
      fdflags = 0
      fdflags |= Wasi::FD_APPEND if (flags & File::APPEND) != 0
      fdflags |= Wasi::FD_NONBLOCK if (flags & File::NONBLOCK) != 0
      [Wasi.to_ftype(file.stat.ftype), fdflags]
    end

    private

    # @rbs store: Wardite::Store
    # @rbs fd: Integer
    # @rbs iovs: Integer
    # @rbs count: Integer
    # @rbs written_at: Integer
    # @rbs return: Integer
    def fd_write_i32(store, fd, iovs, count, written_at)
      file = fd_table[fd]
      return Wasi::EBADF if !file || file.is_a?(Wasi::PreopenedDir)

      memory = store.memories[0]
      return Wasi::EFAULT unless memory && memory.range?(written_at, 4) && memory.range?(iovs, count * 8)

      if count == 1
        payload = iovec_payload(memory, iovs)
        return Wasi::EFAULT unless payload
        written = file.write(payload)
      else
        # Validate every guest buffer before any write to the descriptor.
        payloads = [] #: Array[String]
        total = 0
        count.times do |index|
          payload = iovec_payload(memory, iovs + index * 8)
          return Wasi::EFAULT unless payload
          total += payload.bytesize
          return Wasi::EOVERFLOW if total > 0xffffffff
          payloads << payload
        end
        written = 0
        payloads.each do |payload|
          bytes = file.write(payload)
          written += bytes
          break if bytes < payload.bytesize
        end
      end
      memory.write_bytes(written_at, [written].pack("V"))
      0
    rescue SystemCallError => error
      filesystem_errno(error)
    rescue IOError
      Wasi::EBADF
    end

    # @rbs memory: Wardite::Memory
    # @rbs iov: Integer
    # @rbs return: String?
    def iovec_payload(memory, iov)
      offset = memory.read_u32(iov)
      length = memory.read_u32(iov + 4)
      return nil unless memory.range?(offset, length)
      memory.read_bytes(offset, length)
    end

    # Bind the boxed host call to known methods when compiling with Spinel.
    # @rbs name: Symbol
    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: wasmFuncReturn
    def dispatch_native_import(name, store, args)
      case name
      when :args_get then args_get(store, args)
      when :args_sizes_get then args_sizes_get(store, args)
      when :environ_get then environ_get(store, args)
      when :environ_sizes_get then environ_sizes_get(store, args)
      when :clock_res_get then clock_res_get(store, args)
      when :clock_time_get then clock_time_get(store, args)
      when :fd_close then fd_close(store, args)
      when :fd_fdstat_get then fd_fdstat_get(store, args)
      when :fd_filestat_get then fd_filestat_get(store, args)
      when :fd_prestat_get then fd_prestat_get(store, args)
      when :fd_prestat_dir_name then fd_prestat_dir_name(store, args)
      when :fd_read then fd_read(store, args)
      when :fd_readdir then fd_readdir(store, args)
      when :fd_tell then fd_tell(store, args)
      when :fd_write then fd_write(store, args)
      when :path_create_directory then path_create_directory(store, args)
      when :path_filestat_get then path_filestat_get(store, args)
      when :path_filestat_set_times then path_filestat_set_times(store, args)
      when :path_link then path_link(store, args)
      when :path_open then path_open(store, args)
      when :path_readlink then path_readlink(store, args)
      when :path_remove_directory then path_remove_directory(store, args)
      when :path_rename then path_rename(store, args)
      when :path_symlink then path_symlink(store, args)
      when :path_unlink_file then path_unlink_file(store, args)
      when :proc_exit then proc_exit(store, args)
      when :random_get then random_get(store, args)
      else fd_advise(store, args)
      end
    end

    # @rbs fd: Integer
    # @rbs path: String
    # @rbs return: String | Integer
    def directory_path(fd, path)
      file = @fd_table[fd]
      return Wasi::EBADF unless file
      return Wasi::ENOTDIR unless file.is_a?(Wasi::PreopenedDir) || (file.is_a?(File) && file.stat.directory?)
      return Wasi::EINVAL if path.include?("\0")

      get_path_at(fd, path)
    end

    # @rbs error: SystemCallError
    # @rbs return: Integer
    def filesystem_errno(error)
      if RUBY_ENGINE == "spinel"
        Wasi::Native.wardite_wasi_errno(error.errno || 0)
      else
        case error
        when Errno::EACCES then Wasi::EACCES
        when Errno::EBADF then Wasi::EBADF
        when Errno::EINVAL then Wasi::EINVAL
        when Errno::ELOOP then Wasi::ELOOP
        when Errno::ENAMETOOLONG then Wasi::ENAMETOOLONG
        when Errno::ENOENT then Wasi::ENOENT
        when Errno::ENOTDIR then Wasi::ENOTDIR
        when Errno::EPERM then Wasi::EPERM
        else Wasi::EIO
        end
      end
    end

    # @rbs stat: File::Stat
    # @rbs return: String
    def filestat_bytes(stat)
      timestamps = [stat.atime, stat.mtime, stat.ctime].map { |time| time.to_i * 1_000_000_000 + time.nsec }
      [stat.dev, stat.ino, Wasi.to_ftype(stat.ftype), stat.nlink, stat.size, *timestamps].pack("Q<2Cx7Q<5")
    end

    # @rbs return: Array[String]
    def environment_entries
      ENV.map { |key, value| "#{key}=#{value}\0".b }
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs count: Integer
    # @rbs length: Integer
    # @rbs return: Integer
    def write_guest_sizes(store, args, count, length)
      count_at = args.fetch(0).value.to_i
      size_at = args.fetch(1).value.to_i
      memory = store.memories[0]
      return Wasi::EFAULT unless memory && memory.range?(count_at, 4) && memory.range?(size_at, 4)

      memory.write_bytes(count_at, [count].pack("V"))
      memory.write_bytes(size_at, [length].pack("V"))
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs entries: Array[String]
    # @rbs return: Integer
    def write_guest_strings(store, args, entries)
      pointers_at = args.fetch(0).value.to_i
      entries_at = args.fetch(1).value.to_i
      memory = store.memories[0]
      return Wasi::EFAULT unless memory && memory.range?(pointers_at, entries.size * 4) &&
        memory.range?(entries_at, entries.sum(&:bytesize))

      entries.each do |entry|
        memory.write_bytes(pointers_at, [entries_at].pack("V"))
        memory.write_bytes(entries_at, entry)
        pointers_at += 4
        entries_at += entry.bytesize
      end
      0
    end

    # @rbs store: Store
    # @rbs offset: Integer
    # @rbs length: Integer
    # @rbs return: String?
    def guest_path(store, offset, length)
      memory = store.memories[0]
      return nil unless memory && memory.range?(offset, length)
      memory.read_bytes(offset, length)
    end

    # @rbs store: Store
    # @rbs clock_id: Integer
    # @rbs offset: Integer
    # @rbs resolution: bool
    # @rbs return: Integer
    def write_clock(store, clock_id, offset, resolution:)
      clock = case clock_id
      when 0 then Process::CLOCK_REALTIME
      when 1 then Process::CLOCK_MONOTONIC
      else return Wasi::EINVAL
      end
      memory = store.memories[0]
      return Wasi::EFAULT unless memory && memory.range?(offset, 8)

      ns = resolution ? Process.clock_getres(clock, :nanosecond) : Process.clock_gettime(clock, :nanosecond)
      memory.write_bytes(offset, [ns].pack("Q<"))
      0
    end
  end
end
