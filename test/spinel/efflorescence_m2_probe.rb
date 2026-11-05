# frozen_string_literal: true
# rbs_inline: enabled

# Keep the API receiver concrete when passing specialized argument arrays from
# iterator blocks; Spinel otherwise drops this method from polymorphic dispatch.
class M2Probe
  # @rbs vm: Wardite::Efflorescence::VM
  # @rbs name: String
  # @rbs arguments: Array[Object]
  # @rbs return: Integer?
  def self.call(vm, name, arguments)
    vm.call_unboxed(name, arguments)
  end
end
