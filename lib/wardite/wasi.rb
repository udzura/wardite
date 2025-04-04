# rbs_inline: enabled

require "wardite/wasm_module"
require "wardite/wasi/consts"
require "wardite/wasi/preopens"
require "wardite/wasi/dirent_cache"
require "securerandom"
require "fcntl"

module Wardite
  class WasiSnapshotPreview1
    include ValueHelper
    include WasmModule

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
        open_flags |= File::Constants::NOFOLLOW
      end
      if oflags & Wasi::O_DIRECTORY != 0
        # open_flags |= File::Constants::DIRECTORY
        $stderr.puts "O_DIRECTORY is not supported, ignore" if ENV["WARDITE_TRACE"]
      elsif oflags & Wasi::O_EXCL != 0
        open_flags |= File::Constants::EXCL
      end

      default_mode = File::Constants::RDONLY
      if oflags & Wasi::O_TRUNC != 0
        open_flags |= File::Constants::TRUNC
        default_mode = File::Constants::RDWR
      end
      if oflags & Wasi::O_CREAT != 0
        open_flags |= File::Constants::CREAT
        default_mode = File::Constants::RDWR
      end
      if fdflags & Wasi::FD_NONBLOCK != 0
        open_flags |= File::Constants::NONBLOCK
      end
      if fdflags & Wasi::FD_APPEND != 0
        open_flags |= File::Constants::APPEND
        default_mode = File::Constants::RDWR
      end
      if fdflags & Wasi::FD_DSYNC != 0
        open_flags |= File::Constants::DSYNC
      end
      if fdflags & Wasi::FD_RSYNC != 0
        open_flags |= File::Constants::RSYNC
      end
      if fdflags & Wasi::FD_SYNC != 0
        open_flags |= File::Constants::SYNC
      end

      r = Wasi::RIGHT_FD_READ
      w = Wasi::RIGHT_FD_WRITE
      rw = r | w
      case
      when (rights & rw) == rw
        open_flags |= File::Constants::RDWR
      when (rights & w) == w
        open_flags |= File::Constants::WRONLY
      when (rights & r) == r
        open_flags |= File::Constants::RDONLY
      else
        open_flags |= default_mode
      end

      open_flags
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def args_get(store, args)
      arg_offsets_p = args[0].value
      arg_data_buf_p = args[1].value
      if !arg_data_buf_p.is_a?(Integer)
        raise ArgumentError, "invalid type of args: #{args.inspect}"
      end

      arg_offsets = [] #: Array[Integer]
      arg_data_slice = [] #: Array[String]
      current_offset = arg_data_buf_p
      @argv.each do |arg|
        arg_offsets << current_offset
        arg_data_slice << arg
        current_offset += arg.size + 1
      end
      arg_data = arg_data_slice.join("\0") + "\0"

      memory = store.memories[0]
      memory.data[arg_data_buf_p...(arg_data_buf_p + arg_data.size)] = arg_data

      arg_offsets.each_with_index do |offset, i|
        data_begin = arg_offsets_p + i * 4
        memory.data[data_begin...(data_begin + 4)] = [offset].pack("I!")
      end

      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def args_sizes_get(store, args)
      argc_p = args[0].value
      arglen_p = args[1].value
      argc = @argv.length
      arglen = @argv.map{|arg| arg.size + 1}.sum

      memory = store.memories[0]
      memory.data[argc_p...(argc_p+4)] = [argc].pack("I!")
      memory.data[arglen_p...(arglen_p+4)] = [arglen].pack("I!")
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def environ_sizes_get(store, args)
      envc_p = args[0].value
      envlen_p = args[1].value
      envc = ENV.length
      envlen = ENV.map{|k,v| k.size + v.size + 1}.sum

      memory = store.memories[0]
      memory.data[envc_p...(envc_p+4)] = [envc].pack("I!")
      memory.data[envlen_p...(envlen_p+4)] = [envlen].pack("I!")
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def environ_get(store, args)
      environ_offsets_p = args[0].value
      environ_data_buf_p = args[1].value
      if !environ_data_buf_p.is_a?(Integer)
        raise ArgumentError, "invalid type of args: #{args.inspect}"
      end

      environ_offsets = [] #: Array[Integer]
      environ_data_slice = [] #: Array[String]
      current_offset = environ_data_buf_p
      ENV.each do |k, v|
        environ_offsets << current_offset
        environ_data_slice << "#{k}=#{v}"
        current_offset += "#{k}=#{v}".size + 1
      end
      environ_data = environ_data_slice.join("\0") + "\0"

      memory = store.memories[0]
      memory.data[environ_data_buf_p...(environ_data_buf_p + environ_data.size)] = environ_data

      environ_offsets.each_with_index do |offset, i|
        data_begin = environ_offsets_p + i * 4
        memory.data[data_begin...(data_begin + 4)] = [offset].pack("I!")
      end

      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def clock_time_get(store, args)
      clock_id = args[0].value
      # we dont use precision...
      _precision = args[1].value
      timebuf64 = args[2].value
      if clock_id != 0 # - CLOCKID_REALTIME
        # raise NotImplementedError, "CLOCKID_REALTIME is an only supported id"
        return -255
      end
      # timestamp in nanoseconds
      now = Time.now.to_i * 1_000_000

      memory = store.memories[0]
      now_packed = [now].pack("Q!")
      memory.data[timebuf64...(timebuf64+8)] = now_packed
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def path_create_directory(store, args)
      fd = args[0].value.to_i
      path = args[1].value.to_i
      path_len = args[2].value.to_i
      path_str = store.memories[0].data[path...(path+path_len)]
      if !path_str
        return Wasi::ENOENT
      end

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
      target = get_path_at(fd, store.memories[0].data[path...(path+path_len)].to_s)

      stat = File.stat(target)
      memory = store.memories[0]
      binformat = [
        stat.dev, stat.ino, Wasi.to_ftype(stat.ftype), stat.nlink,
        stat.size, stat.atime.to_i, stat.mtime.to_i, stat.ctime.to_i
      ].pack("Q8")
      memory.data[flags...(flags+binformat.size)] = binformat
      0
    rescue Errno::ENOENT
      return Wasi::ENOENT
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
      target = get_path_at(fd, store.memories[0].data[path...(path+path_len)].to_s)

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
      old_name = get_path_at(old_fd, store.memories[0].data[old_path...(old_path+old_path_len)].to_s)

      new_fd = args[3].value.to_i
      new_path = args[4].value.to_i
      new_path_len = args[5].value.to_i
      new_name = get_path_at(new_fd, store.memories[0].data[new_path...(new_path+new_path_len)].to_s)

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

      path_name = get_path_at(dirfd, store.memories[0].data[path...(path+path_len)].to_s)
      open_flags = interpret_open_flags(dirflags, oflags, fs_flags, fs_rights_base)
      is_dir = (oflags & Wasi::O_DIRECTORY) != 0
      if is_dir && (oflags & Wasi::O_CREAT) != 0
        return Wasi::EINVAL
      end

      file = File.open(path_name, open_flags, 0600)
      fd = set_fd file

      memory = store.memories[0]
      memory.data[fd_off...(fd_off+4)] = [fd].pack("I!")
      0
    rescue Errno::ENOENT
      return Wasi::ENOENT
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

      if buf_len <= 0 || path_len <= 0
        return Wasi::EINVAL
      end
      target = get_path_at(fd, store.memories[0].data[path...(path+path_len)].to_s)

      link_target = File.readlink(target)
      if link_target.size > buf_len
        return Wasi::ENAMETOOLONG
      end

      memory = store.memories[0]
      memory.data[buf...(buf+link_target.size)] = link_target
      memory.data[result_buf...(result_buf+4)] = [link_target.size].pack("I!")
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def path_remove_directory(store, args)
      fd = args[0].value.to_i
      path = args[1].value.to_i
      path_len = args[2].value.to_i
      path_str = store.memories[0].data[path...(path+path_len)].to_s
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

      old_target = get_path_at(fd, store.memories[0].data[old_path...(old_path+old_path_len)].to_s)
      new_target = get_path_at(new_fd, store.memories[0].data[new_path...(new_path+new_path_len)].to_s)

      File.rename(old_target, new_target)
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def path_symlink(store, args)
      old_path = args[0].value.to_i
      old_path_len = args[1].value.to_i
      old_name = store.memories[0].data[old_path...(old_path+old_path_len)].to_s

      fd = args[2].value.to_i
      new_path = args[3].value.to_i
      new_path_len = args[4].value.to_i
      new_name = get_path_at(fd, store.memories[0].data[new_path...(new_path+new_path_len)].to_s)

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
      path_str = store.memories[0].data[path...(path+path_len)].to_s
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
      name = file.path
      memory = store.memories[0]
      # Zero-value 8-bit tag, and 3-byte zero-value padding
      memory.data[prestat_offset...(prestat_offset+4)] = [0].pack("I!")
      memory.data[(prestat_offset+4)...(prestat_offset+8)] = [name.size].pack("I!")
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
      name = file.path
      if name.size > path_len
        return Wasi::ENAMETOOLONG
      end
      name += ("\0" * (path_len - name.size))

      memory = store.memories[0]
      memory.data[path...(path+name.size)] = name
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def fd_write(store, args)
      iargs = args.map do |elm|
        if elm.is_a?(I32)
          elm.value
        else
          raise Wardite::ArgumentError, "invalid type of args: #{args.inspect}"
        end
      end #: Array[Integer]
      fd, iovs, iovs_len, rp = *iargs
      if !fd || !iovs || !iovs_len || !rp
        raise Wardite::ArgumentError, "args too short"
      end
      file = self.fd_table[fd]
      return Wasi::EBADF if !file || file.is_a?(Wasi::PreopenedDir)
      memory = store.memories[0]
      nwritten = 0
      iovs_len.times do
        start = unpack_le_int(memory.data[iovs...(iovs+4)])
        iovs += 4
        slen = unpack_le_int(memory.data[iovs...(iovs+4)])
        iovs += 4
        # TODO: parallel write?
        nwritten += file.write(memory.data[start...(start+slen)])
      end

      memory.data[rp...(rp+4)] = [nwritten].pack("I!")

      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def fd_read(store, args)
      iargs = args.map do |elm|
        if elm.is_a?(I32)
          elm.value
        else
          raise Wardite::ArgumentError, "invalid type of args: #{args.inspect}"
        end
      end #: Array[Integer]
      fd, iovs, iovs_len, rp = *iargs
      if !fd || !iovs || !iovs_len || !rp
        raise Wardite::ArgumentError, "args too short"
      end
      file = self.fd_table[fd]
      return Wasi::EBADF if !file || file.is_a?(Wasi::PreopenedDir)
      memory = store.memories[0]
      nread = 0
      
      iovs_len.times do
        start = unpack_le_int(memory.data[iovs...(iovs+4)])
        iovs += 4
        slen = unpack_le_int(memory.data[iovs...(iovs+4)])
        iovs += 4
        buf = file.read(slen)
        if !buf
          break 0
        end
        memory.data[start...(start+buf.size)] = buf
        nread += buf.size
      end

      memory.data[rp...(rp+4)] = [nread].pack("I!")
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def fd_fdstat_get(store, args)
      fd = args[0].value.to_i
      fdstat_offset = args[1].value.to_i
      if fd >= fd_count
        return Wasi::EBADF
      end
      file = @fd_table[fd]
      fdflags = 0
      if !file
        return Wasi::EBADF
      elsif file.is_a?(Wasi::PreopenedDir)
        file = File.open(file.guest_path) # reopen directory
      elsif file.is_a?(IO) && !file.is_a?(File)
        fdflags |= Wasi::FD_APPEND
      else
        if (Fcntl::O_APPEND & file.fcntl(Fcntl::F_GETFL, 0)) != 0
          fdflags |= Wasi::FD_APPEND
        end
      end

      if (Fcntl::O_NONBLOCK & file.fcntl(Fcntl::F_GETFL, 0)) != 0
        fdflags |= Wasi::FD_NONBLOCK
      end

      stat = file.stat #: File::Stat
      ftype = Wasi.to_ftype(stat.ftype)

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

      memory = store.memories[0]

      binformat = [fdflags, ftype, 0, 0, 0, 0, fs_right_base, fs_right_inheriting]
        .pack("SSC4QQ")
      memory.data[fdstat_offset...(fdstat_offset+binformat.size)] = binformat
      0
    end

    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: Object
    def fd_filestat_get(store, args)
      fd = args[0].value.to_i
      filestat_offset = args[1].value.to_i
      if fd >= fd_count
        return Wasi::EBADF
      end
      file = @fd_table[fd]
      if !file || file.is_a?(Wasi::PreopenedDir)
        return Wasi::EBADF
      end

      stat = file.stat #: File::Stat
      memory = store.memories[0]
      binformat = [stat.dev, stat.ino, Wasi.to_ftype(stat.ftype), stat.nlink, stat.size, stat.atime.to_i, stat.mtime.to_i, stat.ctime.to_i].pack("Q8")
      memory.data[filestat_offset...(filestat_offset+binformat.size)] = binformat
      0
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
      
      if dirent_cache[fd]&.eof
        dirent_cache.delete(fd)
      end
      dir = @fd_table[fd]
      if dir.is_a?(Wasi::PreopenedDir) || (dir.is_a?(File) && dir.stat.ftype == "directory")
        dirent_cache[fd] ||= Wasi::DirentCache.new(dir.path)
      else
        return Wasi::EBADF
      end

      dirent = dirent_cache[fd]
      bindata, is_truncated = dirent.fetch_entries_binary(buf_len, cookie)

      bufused = bindata.size
      # bufused == buf_len means more dirents exist
      if is_truncated
        bufused = buf_len
        memory.data[buf...(buf+buf_len)] = bindata + "\0" * (buf_len - bindata.size)
      else
        dirent.eof = true
        memory.data[buf...(buf+bindata.size)] = bindata
      end

      memory.data[result_buf_used...(result_buf_used+4)] = [bufused].pack("I!")
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
      memory.data[result_buf...(result_buf+4)] = [file.tell].pack("I!")
      0
    rescue Errno::EBADF
      return Wasi::EBADF
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
    rescue Errno::EBADF
      return Wasi::EBADF      
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
      randoms = SecureRandom.random_bytes(buflen) #: String
      memory = store.memories[0]
      memory.data[buf...(buf+buflen)] = randoms
      0
    end

    private
    # @rbs buf: String|nil
    # @rbs return: Integer
    def unpack_le_int(buf)
      if !buf
        raise "empty buffer"
      end
      ret = buf.unpack1("I")
      if !ret.is_a?(Integer)
        raise "[BUG] invalid pack format"
      end
      ret
    end
  end
end