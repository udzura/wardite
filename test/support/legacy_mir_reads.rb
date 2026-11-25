# frozen_string_literal: true

module LegacyMIRReads
  include Wardite::Efflorescence::Opcode

  def self.positions(instruction)
    opcode = instruction[0]
    # A sequence header has the operand roles of the first instruction.
    opcode = SEQUENCE_HEADS.fetch(opcode - I32_TABLE_STORE8) if opcode.between?(I32_TABLE_STORE8, I64_BYTE_LOOKUP_BR_EQ)
    case opcode
    when RESULT_SET, TABLE_GET, REF_IS_NULL, GLOBAL_SET, I32_LOAD, I32_LOAD8_S, I32_LOAD8_U, I32_LOAD16_S, I32_LOAD16_U, MEMORY_GROW,
         COPY, COPY_REF, I32_EQZ, I32_CLZ, I32_CTZ, I32_POPCNT, I32_EXTEND8_S, I32_EXTEND16_S, I32_ADD_IMM, I32_SUB_IMM, I32_MUL_IMM,
         I32_XOR_IMM, I32_SHL_IMM, I32_SHR_U_IMM, I32_XOR_SHR_U_IMM, I32_XOR_SHL_IMM
      [2]
    when I32_ADD, I32_SUB, I32_MUL, I32_XOR, I32_SHL, I32_SHR_U,
         I32_EQ, I32_NE, I32_LTS, I32_LTU, I32_GTS, I32_GTU, I32_LES, I32_LEU, I32_GES, I32_GEU,
         I32_DIV_S, I32_DIV_U, I32_REM_S, I32_REM_U, I32_AND, I32_OR, I32_SHR_S, I32_ROTL, I32_ROTR
      [2, 3]
    when BR_IF_I64_EQ
      [1, 3]
    when BR_IF, BR_IF_ZERO
      [1]
    when CALL
      (3...instruction.size).to_a
    when CALL_INDIRECT
      [3]
    when RETURN
      instruction[1] < 0 ? [] : [1]
    when I32_STORE, I32_STORE8, I32_STORE16
      [1, 2]
    when THROW_REF
      [1]
    when RESULT_GET, BR, TRAP, PROFILE, EH_ENTER, EH_TRIM, THROW, GLOBAL_GET, MEMORY_SIZE, MEMORY_INIT, MEMORY_COPY, MEMORY_FILL, CALL_HOST
      []
    else
      types = Wardite::Efflorescence::Opcode.extended_alu_types(opcode)
      return types.size == 2 ? [2] : [2, 3] if types
      return [2] if EXTENDED_LOAD_TYPES.key?(opcode) || EXTENDED_GLOBAL_SET_TYPES.key?(opcode)
      return [1, 2] if EXTENDED_STORE_TYPES.key?(opcode)
      return [] if EXTENDED_GLOBAL_GET_TYPES.key?(opcode)

      raise Wardite::Efflorescence::UnsupportedFeature, "Efflorescence: unknown MIR opcode #{opcode}"
    end
  end
end
