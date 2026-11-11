# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Wasi
    module Native
      # @rbs!
      #   def self.ffi_source: (String) -> void
      #   def self.ffi_func: (Symbol, Array[Symbol], Symbol) -> void
      #   def self.wardite_wasi_getfl: (Integer) -> Integer
      #   def self.wardite_wasi_errno: (Integer) -> Integer

      ffi_source <<~C
        #include <fcntl.h>
        #include <errno.h>
        int wardite_wasi_getfl(int fd) {
        #ifdef F_GETFL
          return fcntl(fd, F_GETFL);
        #else
          return 0;
        #endif
        }
        int wardite_wasi_errno(int error) {
          switch (error) {
            case EACCES: return 2;
            case EBADF: return 8;
            case EINVAL: return 28;
            case ELOOP: return 32;
            case ENAMETOOLONG: return 37;
            case ENOENT: return 44;
            case ENOTDIR: return 54;
            case EPERM: return 63;
            default: return 29;
          }
        }
      C
      ffi_func :wardite_wasi_getfl, [:int], :int
      ffi_func :wardite_wasi_errno, [:int], :int
    end
  end
end
