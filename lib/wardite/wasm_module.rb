# rbs_inline: enabled

module Wardite
  # @rbs!
  #   interface _WasmCallable
  #     def call: (Store, Array[wasmValue]) -> wasmFuncReturn
  #     def []: (Store, Array[wasmValue]) -> wasmFuncReturn
  #   end

  # @rbs!
  #   type wasmModuleSrc = Hash[Symbol, _WasmCallable] | WasmModule | HashModule
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
    # @rbs return: _WasmCallable
    def callable(fnname)
      self.method(fnname)
    end
  end

  class HashModule
    attr_accessor :hash #: Hash[Symbol, _WasmCallable]

    # @rbs ha: Hash[Symbol, _WasmCallable]
    def initialize(hash)
      @hash = hash
    end

    # @rbs fnname: Symbol
    # @rbs store: Store
    # @rbs args: Array[wasmValue]
    # @rbs return: wasmFuncReturn
    def invoke(fnname, store, *args)
      fn = callable(fnname)
      fn.call(store, args)
    end

    # @rbs fnname: Symbol
    # @rbs return: _WasmCallable
    def callable(fnname)
      name = fnname.to_sym
      fn = self.hash.fetch(name) { self.hash.default(name) }
      raise NameError, "function #{fnname} not found" unless fn
      fn
    end
  end
end
