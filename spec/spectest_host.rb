# frozen_string_literal: true

require "wardite"

class SpectestHost < Wardite::HashModule
  PARAMETERS = {
    print: [], print_i32: [:i32], print_i64: [:i64],
    print_f32: [:f32], print_f64: [:f64],
    print_i32_f32: [:i32, :f32], print_f64_f64: [:f64, :f64]
  }.freeze

  def initialize
    global = Wardite::Global.numeric(:i32, false)
    global.value = Wardite::I32(666)
    wide = Wardite::Global.numeric(:i64, false)
    wide.value = Wardite::I64(666)
    super({}, {global_i32: global, global_i64: wide})
    printer = ->(_store, args) { args.each { |arg| puts arg.value }; nil }
    PARAMETERS.each_key { |name| register_function(name, printer) }
  end

  def validate_function_import(name, callsig, retsig)
    parameters = PARAMETERS[name]
    unless parameters
      raise Wardite::LinkError, "incompatible import type" if globals.key?(name)
      raise Wardite::LinkError, "unknown import"
    end
    unless parameters == callsig && retsig.empty?
      raise Wardite::LinkError, "incompatible import type"
    end
  end
end
