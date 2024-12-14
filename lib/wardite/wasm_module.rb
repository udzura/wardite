# rbs_inline: enabled

module Wardite
  # @rbs!
  #   type wasmModuleSrc = Hash[Symbol, wasmCallable] | WasmModule | HashModule
  #   type wasmModule    = WasmModule | HashModule

  module WasmModule
    # @rbs fnname: Symbol
    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: wasmFuncReturn
    def invoke(fnname, store, *args)
      self.__send__(fnname, store, args)
    end

    # @rbs fnname: Symbol
    # @rbs return: wasmCallable
    def callable(fnname)
      # FIXME: RBS can resolve Method instance signature in the future?
      self.method(fnname) #: untyped
    end
  end

  class HashModule
    attr_accessor :hash #: Hash[Symbol, wasmCallable]

    # @rbs ha: Hash[Symbol, wasmCallable]
    def initialize(hash)
      @hash = hash
    end

    # @rbs fnname: Symbol
    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: wasmFuncReturn
    def invoke(fnname, store, *args)
      fn = self.hash[fnname.to_sym]
      fn.call(store, args)
    end

    # @rbs fnname: Symbol
    # @rbs return: wasmCallable
    def callable(fnname)
      self.hash[fnname.to_sym]
    end
  end
end