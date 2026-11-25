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

    attr_reader :tags #: Hash[Symbol, Efflorescence::Tag]

    attr_reader :tables #: Hash[Symbol, Table]

    attr_reader :memories #: Hash[Symbol, Memory]

    attr_reader :globals #: Hash[Symbol, Global]

    # @rbs hash: Hash[Symbol, _WasmCallable]
    # @rbs globals: Hash[Symbol, Global]
    def initialize(hash, globals = {})
      @tags = {}
      @tables = {} #: Hash[Symbol, Table]
      @memories = {} #: Hash[Symbol, Memory]
      @globals = globals
      @hash = hash
    end

    # @rbs name: Symbol
    # @rbs return: bool
    def export_named?(name)
      @hash.key?(name) || @tables.key?(name) || @memories.key?(name) || @globals.key?(name) || @tags.key?(name)
    end

    # @rbs name: Symbol
    # @rbs return: ExportedFunction?
    def exported_function(name)
      function = @hash.fetch(name, nil) #: (_WasmCallable & Object)?
      function if function.is_a?(ExportedFunction)
    end

    # @rbs name: Symbol
    # @rbs callsig: Array[Symbol]
    # @rbs retsig: Array[Symbol]
    # @rbs return: void
    def validate_function_import(name, callsig, retsig)
      unless @hash.key?(name)
        raise LinkError, export_named?(name) ? "incompatible import type" : "unknown import"
      end
      exported = exported_function(name)
      return unless exported.is_a?(ExportedFunction)
      original = exported.instance.exports[exported.name]
      unless (original.is_a?(WasmFunction) || original.is_a?(ExternalFunction)) && original.callsig == callsig && original.retsig == retsig
        raise LinkError, "incompatible import type"
      end
    end

    # @rbs name: Symbol
    # @rbs function: _WasmCallable
    # @rbs return: void
    def register_function(name, function)
      @hash[name] = function
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
