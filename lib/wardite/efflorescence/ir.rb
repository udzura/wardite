# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    class UnsupportedFeature < Wardite::LoadError; end
    class TranslationError < Wardite::LoadError; end

    module Opcode
      COPY = 0
      I32_ADD = 1
      I32_SUB = 2
      I32_MUL = 3
      I32_XOR = 4
      I32_SHL = 5
      I32_SHR_U = 6
      I32_EQZ = 7
      BR = 8
      BR_IF = 9
      CALL = 10
      RETURN = 11
      TRAP = 12
      I32_ADD_IMM = 13
      I32_SUB_IMM = 14
      I32_MUL_IMM = 15
      I32_XOR_IMM = 16
      I32_SHL_IMM = 17
      I32_SHR_U_IMM = 18
      BR_IF_ZERO = 19
      I32_XOR_SHR_U_IMM = 20
      I32_XOR_SHL_IMM = 21
      PROFILE = 22

      I32_EQ = 23
      I32_NE = 24
      I32_LTS = 25
      I32_LTU = 26
      I32_GTS = 27
      I32_GTU = 28
      I32_LES = 29
      I32_LEU = 30
      I32_GES = 31
      I32_GEU = 32
      I32_CLZ = 33
      I32_CTZ = 34
      I32_POPCNT = 35
      I32_DIV_S = 36
      I32_DIV_U = 37
      I32_REM_S = 38
      I32_REM_U = 39
      I32_AND = 40
      I32_OR = 41
      I32_SHR_S = 42
      I32_ROTL = 43
      I32_ROTR = 44
      I32_EXTEND8_S = 45
      I32_EXTEND16_S = 46
      COPY_REF = 47
      EH_ENTER = 48
      EH_TRIM = 49
      THROW = 50
      THROW_REF = 51

      GLOBAL_GET = 52
      GLOBAL_SET = 53
      I32_LOAD = 54
      I32_LOAD8_S = 55
      I32_LOAD8_U = 56
      I32_LOAD16_S = 57
      I32_LOAD16_U = 58
      I32_STORE = 59
      I32_STORE8 = 60
      I32_STORE16 = 61
      MEMORY_SIZE = 62
      MEMORY_GROW = 63
      MEMORY_INIT = 64
      MEMORY_COPY = 65
      MEMORY_FILL = 66
      CALL_HOST = 67
      CALL_INDIRECT = 68

      I64_EQZ = 69
      I32_WRAP_I64 = 70
      I64_EQ = 71
      I64_NE = 72
      I64_LTS = 73
      I64_LTU = 74
      I64_GTS = 75
      I64_GTU = 76
      I64_LES = 77
      I64_LEU = 78
      I64_GES = 79
      I64_GEU = 80
      I64_CLZ = 81
      I64_CTZ = 82
      I64_POPCNT = 83
      I64_EXTEND8_S = 84
      I64_EXTEND16_S = 85
      I64_EXTEND32_S = 86
      I64_EXTEND_I32_S = 87
      I64_EXTEND_I32_U = 88
      I64_AND = 89
      I64_OR = 90
      I64_XOR = 91
      I64_SHL = 92
      I64_SHR_S = 93
      I64_SHR_U = 94
      I64_ROTL = 95
      I64_ROTR = 96

      I64_ADD = 97
      I64_SUB = 98
      I64_MUL = 99
      I64_DIV_S = 100
      I64_DIV_U = 101
      I64_REM_S = 102
      I64_REM_U = 103

      I64_LOAD = 104
      I64_LOAD8_S = 105
      I64_LOAD8_U = 106
      I64_LOAD16_S = 107
      I64_LOAD16_U = 108
      I64_LOAD32_S = 109
      I64_LOAD32_U = 110
      I64_STORE = 111
      I64_STORE8 = 112
      I64_STORE16 = 113
      I64_STORE32 = 114
      I64_GLOBAL_GET = 115
      I64_GLOBAL_SET = 116

      F32_EQ = 117
      F32_NE = 118
      F32_LT = 119
      F32_GT = 120
      F32_LE = 121
      F32_GE = 122
      F32_ABS = 123
      F32_NEG = 124
      F32_CEIL = 125
      F32_FLOOR = 126
      F32_TRUNC = 127
      F32_NEAREST = 128
      F32_SQRT = 129
      F32_ADD = 130
      F32_SUB = 131
      F32_MUL = 132
      F32_DIV = 133
      F32_MIN = 134
      F32_MAX = 135
      F32_COPYSIGN = 136
      F64_EQ = 137
      F64_NE = 138
      F64_LT = 139
      F64_GT = 140
      F64_LE = 141
      F64_GE = 142
      F64_ABS = 143
      F64_NEG = 144
      F64_CEIL = 145
      F64_FLOOR = 146
      F64_TRUNC = 147
      F64_NEAREST = 148
      F64_SQRT = 149
      F64_ADD = 150
      F64_SUB = 151
      F64_MUL = 152
      F64_DIV = 153
      F64_MIN = 154
      F64_MAX = 155
      F64_COPYSIGN = 156

      I32_TRUNC_F32_S = 157
      I32_TRUNC_F32_U = 158
      I32_TRUNC_F64_S = 159
      I32_TRUNC_F64_U = 160
      I64_TRUNC_F32_S = 161
      I64_TRUNC_F32_U = 162
      I64_TRUNC_F64_S = 163
      I64_TRUNC_F64_U = 164
      I32_TRUNC_SAT_F32_S = 165
      I32_TRUNC_SAT_F32_U = 166
      I32_TRUNC_SAT_F64_S = 167
      I32_TRUNC_SAT_F64_U = 168
      I64_TRUNC_SAT_F32_S = 169
      I64_TRUNC_SAT_F32_U = 170
      I64_TRUNC_SAT_F64_S = 171
      I64_TRUNC_SAT_F64_U = 172
      F32_CONVERT_I32_S = 173
      F32_CONVERT_I32_U = 174
      F32_CONVERT_I64_S = 175
      F32_CONVERT_I64_U = 176
      F64_CONVERT_I32_S = 177
      F64_CONVERT_I32_U = 178
      F64_CONVERT_I64_S = 179
      F64_CONVERT_I64_U = 180
      F32_DEMOTE_F64 = 181
      F64_PROMOTE_F32 = 182
      I32_REINTERPRET_F32 = 183
      I64_REINTERPRET_F64 = 184
      F32_REINTERPRET_I32 = 185
      F64_REINTERPRET_I64 = 186

      F32_LOAD = 187
      F64_LOAD = 188
      F32_STORE = 189
      F64_STORE = 190
      F32_GLOBAL_GET = 191
      F64_GLOBAL_GET = 192
      F32_GLOBAL_SET = 193
      F64_GLOBAL_SET = 194

      NAMES = %w[COPY I32_ADD I32_SUB I32_MUL I32_XOR I32_SHL I32_SHR_U I32_EQZ
                 BR BR_IF CALL RETURN TRAP I32_ADD_IMM I32_SUB_IMM I32_MUL_IMM
                 I32_XOR_IMM I32_SHL_IMM I32_SHR_U_IMM BR_IF_ZERO
                 I32_XOR_SHR_U_IMM I32_XOR_SHL_IMM PROFILE
                 I32_EQ I32_NE I32_LTS I32_LTU I32_GTS I32_GTU I32_LES I32_LEU I32_GES I32_GEU I32_CLZ I32_CTZ I32_POPCNT I32_DIV_S I32_DIV_U I32_REM_S I32_REM_U I32_AND I32_OR I32_SHR_S I32_ROTL I32_ROTR I32_EXTEND8_S I32_EXTEND16_S COPY_REF EH_ENTER EH_TRIM THROW THROW_REF
                 GLOBAL_GET GLOBAL_SET I32_LOAD I32_LOAD8_S I32_LOAD8_U I32_LOAD16_S I32_LOAD16_U I32_STORE I32_STORE8 I32_STORE16 MEMORY_SIZE MEMORY_GROW MEMORY_INIT MEMORY_COPY MEMORY_FILL CALL_HOST CALL_INDIRECT
                 I64_EQZ I32_WRAP_I64
                 I64_EQ I64_NE I64_LTS I64_LTU I64_GTS I64_GTU I64_LES I64_LEU I64_GES I64_GEU
                 I64_CLZ I64_CTZ I64_POPCNT I64_EXTEND8_S I64_EXTEND16_S I64_EXTEND32_S
                 I64_EXTEND_I32_S I64_EXTEND_I32_U
                 I64_AND I64_OR I64_XOR I64_SHL I64_SHR_S I64_SHR_U I64_ROTL I64_ROTR
                 I64_ADD I64_SUB I64_MUL I64_DIV_S I64_DIV_U I64_REM_S I64_REM_U
                 I64_LOAD I64_LOAD8_S I64_LOAD8_U I64_LOAD16_S I64_LOAD16_U I64_LOAD32_S I64_LOAD32_U
                 I64_STORE I64_STORE8 I64_STORE16 I64_STORE32 I64_GLOBAL_GET I64_GLOBAL_SET
                 F32_EQ F32_NE F32_LT F32_GT F32_LE F32_GE F32_ABS F32_NEG
                 F32_CEIL F32_FLOOR F32_TRUNC F32_NEAREST F32_SQRT F32_ADD F32_SUB F32_MUL
                 F32_DIV F32_MIN F32_MAX F32_COPYSIGN F64_EQ F64_NE F64_LT F64_GT
                 F64_LE F64_GE F64_ABS F64_NEG F64_CEIL F64_FLOOR F64_TRUNC F64_NEAREST
                 F64_SQRT F64_ADD F64_SUB F64_MUL F64_DIV F64_MIN F64_MAX F64_COPYSIGN
                 I32_TRUNC_F32_S I32_TRUNC_F32_U I32_TRUNC_F64_S I32_TRUNC_F64_U
                 I64_TRUNC_F32_S I64_TRUNC_F32_U I64_TRUNC_F64_S I64_TRUNC_F64_U
                 I32_TRUNC_SAT_F32_S I32_TRUNC_SAT_F32_U I32_TRUNC_SAT_F64_S I32_TRUNC_SAT_F64_U
                 I64_TRUNC_SAT_F32_S I64_TRUNC_SAT_F32_U I64_TRUNC_SAT_F64_S I64_TRUNC_SAT_F64_U
                 F32_CONVERT_I32_S F32_CONVERT_I32_U F32_CONVERT_I64_S F32_CONVERT_I64_U
                 F64_CONVERT_I32_S F64_CONVERT_I32_U F64_CONVERT_I64_S F64_CONVERT_I64_U
                 F32_DEMOTE_F64 F64_PROMOTE_F32 I32_REINTERPRET_F32 I64_REINTERPRET_F64
                 F32_REINTERPRET_I32 F64_REINTERPRET_I64
                 F32_LOAD F64_LOAD F32_STORE F64_STORE
                 F32_GLOBAL_GET F64_GLOBAL_GET F32_GLOBAL_SET F64_GLOBAL_SET].freeze

      # Each signature lists the destination type followed by the source types.
      I64_ALU_TYPES = {
        I64_EQZ => [:i32, :i64],
        I32_WRAP_I64 => [:i32, :i64],
        I64_EQ => [:i32, :i64, :i64],
        I64_NE => [:i32, :i64, :i64],
        I64_LTS => [:i32, :i64, :i64],
        I64_LTU => [:i32, :i64, :i64],
        I64_GTS => [:i32, :i64, :i64],
        I64_GTU => [:i32, :i64, :i64],
        I64_LES => [:i32, :i64, :i64],
        I64_LEU => [:i32, :i64, :i64],
        I64_GES => [:i32, :i64, :i64],
        I64_GEU => [:i32, :i64, :i64],
        I64_CLZ => [:i64, :i64],
        I64_CTZ => [:i64, :i64],
        I64_POPCNT => [:i64, :i64],
        I64_EXTEND8_S => [:i64, :i64],
        I64_EXTEND16_S => [:i64, :i64],
        I64_EXTEND32_S => [:i64, :i64],
        I64_EXTEND_I32_S => [:i64, :i32],
        I64_EXTEND_I32_U => [:i64, :i32],
        I64_AND => [:i64, :i64, :i64],
        I64_OR => [:i64, :i64, :i64],
        I64_XOR => [:i64, :i64, :i64],
        I64_SHL => [:i64, :i64, :i64],
        I64_SHR_S => [:i64, :i64, :i64],
        I64_SHR_U => [:i64, :i64, :i64],
        I64_ROTL => [:i64, :i64, :i64],
        I64_ROTR => [:i64, :i64, :i64],
        I64_ADD => [:i64, :i64, :i64],
        I64_SUB => [:i64, :i64, :i64],
        I64_MUL => [:i64, :i64, :i64],
        I64_DIV_S => [:i64, :i64, :i64],
        I64_DIV_U => [:i64, :i64, :i64],
        I64_REM_S => [:i64, :i64, :i64],
        I64_REM_U => [:i64, :i64, :i64],
      }.freeze #: Hash[Integer, Array[Symbol]]

      FLOAT_ALU_TYPES = {
        F32_EQ => [:i32, :f32, :f32],
        F32_NE => [:i32, :f32, :f32],
        F32_LT => [:i32, :f32, :f32],
        F32_GT => [:i32, :f32, :f32],
        F32_LE => [:i32, :f32, :f32],
        F32_GE => [:i32, :f32, :f32],
        F32_ABS => [:f32, :f32],
        F32_NEG => [:f32, :f32],
        F32_CEIL => [:f32, :f32],
        F32_FLOOR => [:f32, :f32],
        F32_TRUNC => [:f32, :f32],
        F32_NEAREST => [:f32, :f32],
        F32_SQRT => [:f32, :f32],
        F32_ADD => [:f32, :f32, :f32],
        F32_SUB => [:f32, :f32, :f32],
        F32_MUL => [:f32, :f32, :f32],
        F32_DIV => [:f32, :f32, :f32],
        F32_MIN => [:f32, :f32, :f32],
        F32_MAX => [:f32, :f32, :f32],
        F32_COPYSIGN => [:f32, :f32, :f32],
        F64_EQ => [:i32, :f64, :f64],
        F64_NE => [:i32, :f64, :f64],
        F64_LT => [:i32, :f64, :f64],
        F64_GT => [:i32, :f64, :f64],
        F64_LE => [:i32, :f64, :f64],
        F64_GE => [:i32, :f64, :f64],
        F64_ABS => [:f64, :f64],
        F64_NEG => [:f64, :f64],
        F64_CEIL => [:f64, :f64],
        F64_FLOOR => [:f64, :f64],
        F64_TRUNC => [:f64, :f64],
        F64_NEAREST => [:f64, :f64],
        F64_SQRT => [:f64, :f64],
        F64_ADD => [:f64, :f64, :f64],
        F64_SUB => [:f64, :f64, :f64],
        F64_MUL => [:f64, :f64, :f64],
        F64_DIV => [:f64, :f64, :f64],
        F64_MIN => [:f64, :f64, :f64],
        F64_MAX => [:f64, :f64, :f64],
        F64_COPYSIGN => [:f64, :f64, :f64],
        I32_TRUNC_F32_S => [:i32, :f32],
        I32_TRUNC_F32_U => [:i32, :f32],
        I32_TRUNC_F64_S => [:i32, :f64],
        I32_TRUNC_F64_U => [:i32, :f64],
        I64_TRUNC_F32_S => [:i64, :f32],
        I64_TRUNC_F32_U => [:i64, :f32],
        I64_TRUNC_F64_S => [:i64, :f64],
        I64_TRUNC_F64_U => [:i64, :f64],
        I32_TRUNC_SAT_F32_S => [:i32, :f32],
        I32_TRUNC_SAT_F32_U => [:i32, :f32],
        I32_TRUNC_SAT_F64_S => [:i32, :f64],
        I32_TRUNC_SAT_F64_U => [:i32, :f64],
        I64_TRUNC_SAT_F32_S => [:i64, :f32],
        I64_TRUNC_SAT_F32_U => [:i64, :f32],
        I64_TRUNC_SAT_F64_S => [:i64, :f64],
        I64_TRUNC_SAT_F64_U => [:i64, :f64],
        F32_CONVERT_I32_S => [:f32, :i32],
        F32_CONVERT_I32_U => [:f32, :i32],
        F32_CONVERT_I64_S => [:f32, :i64],
        F32_CONVERT_I64_U => [:f32, :i64],
        F64_CONVERT_I32_S => [:f64, :i32],
        F64_CONVERT_I32_U => [:f64, :i32],
        F64_CONVERT_I64_S => [:f64, :i64],
        F64_CONVERT_I64_U => [:f64, :i64],
        F32_DEMOTE_F64 => [:f32, :f64],
        F64_PROMOTE_F32 => [:f64, :f32],
        I32_REINTERPRET_F32 => [:i32, :f32],
        I64_REINTERPRET_F64 => [:i64, :f64],
        F32_REINTERPRET_I32 => [:f32, :i32],
        F64_REINTERPRET_I64 => [:f64, :i64],
      }.freeze #: Hash[Integer, Array[Symbol]]

      # @rbs opcode: Integer
      # @rbs return: Array[Symbol]?
      def self.extended_alu_types(opcode)
        opcode >= F32_EQ ? FLOAT_ALU_TYPES[opcode] : I64_ALU_TYPES[opcode]
      end

      EXTENDED_LOAD_TYPES = {
        I64_LOAD => :i64,
        I64_LOAD8_S => :i64,
        I64_LOAD8_U => :i64,
        I64_LOAD16_S => :i64,
        I64_LOAD16_U => :i64,
        I64_LOAD32_S => :i64,
        I64_LOAD32_U => :i64,
        F32_LOAD => :f32,
        F64_LOAD => :f64,
      }.freeze #: Hash[Integer, Symbol]

      EXTENDED_STORE_TYPES = {
        I64_STORE => :i64,
        I64_STORE8 => :i64,
        I64_STORE16 => :i64,
        I64_STORE32 => :i64,
        F32_STORE => :f32,
        F64_STORE => :f64,
      }.freeze #: Hash[Integer, Symbol]

      EXTENDED_GLOBAL_GET_TYPES = {
        I64_GLOBAL_GET => :i64,
        F32_GLOBAL_GET => :f32,
        F64_GLOBAL_GET => :f64,
      }.freeze #: Hash[Integer, Symbol]

      EXTENDED_GLOBAL_SET_TYPES = {
        I64_GLOBAL_SET => :i64,
        F32_GLOBAL_SET => :f32,
        F64_GLOBAL_SET => :f64,
      }.freeze #: Hash[Integer, Symbol]

      # These are semantic register accesses, excluding frame initialization.
      # @rbs instruction: Wardite::Efflorescence::Instruction
      # @rbs return: Array[Integer]
      def self.read_positions(instruction)
        opcode = instruction[0]
        case opcode
        when GLOBAL_SET, I32_LOAD, I32_LOAD8_S, I32_LOAD8_U, I32_LOAD16_S, I32_LOAD16_U, MEMORY_GROW,
             COPY, COPY_REF, I32_EQZ, I32_CLZ, I32_CTZ, I32_POPCNT, I32_EXTEND8_S, I32_EXTEND16_S, I32_ADD_IMM, I32_SUB_IMM, I32_MUL_IMM,
             I32_XOR_IMM, I32_SHL_IMM, I32_SHR_U_IMM, I32_XOR_SHR_U_IMM, I32_XOR_SHL_IMM
          [2]
        when I32_ADD, I32_SUB, I32_MUL, I32_XOR, I32_SHL, I32_SHR_U,
             I32_EQ, I32_NE, I32_LTS, I32_LTU, I32_GTS, I32_GTU, I32_LES, I32_LEU, I32_GES, I32_GEU,
             I32_DIV_S, I32_DIV_U, I32_REM_S, I32_REM_U, I32_AND, I32_OR, I32_SHR_S, I32_ROTL, I32_ROTR
          [2, 3]
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
        when BR, TRAP, PROFILE, EH_ENTER, EH_TRIM, THROW, GLOBAL_GET, MEMORY_SIZE, MEMORY_INIT, MEMORY_COPY, MEMORY_FILL, CALL_HOST
          []
        else
          types = extended_alu_types(opcode)
          return types.size == 2 ? [2] : [2, 3] if types
          return [2] if EXTENDED_LOAD_TYPES.key?(opcode) || EXTENDED_GLOBAL_SET_TYPES.key?(opcode)
          return [1, 2] if EXTENDED_STORE_TYPES.key?(opcode)
          return [] if EXTENDED_GLOBAL_GET_TYPES.key?(opcode)

          raise UnsupportedFeature, "Efflorescence: unknown MIR opcode #{opcode}"
        end
      end

      # @rbs instruction: Wardite::Efflorescence::Instruction
      # @rbs return: Integer
      def self.destination(instruction)
        opcode = instruction[0]
        if opcode <= I32_EQZ || opcode == CALL || dynamic_call?(opcode) ||
            (opcode >= I32_ADD_IMM && opcode <= I32_SHR_U_IMM) ||
            opcode == I32_XOR_SHR_U_IMM || opcode == I32_XOR_SHL_IMM ||
            (opcode >= I32_EQ && opcode <= COPY_REF) || opcode == GLOBAL_GET ||
            (opcode >= I32_LOAD && opcode <= I32_LOAD16_U) || opcode == MEMORY_SIZE || opcode == MEMORY_GROW ||
            (opcode > CALL_INDIRECT && (extended_alu_types(opcode) || EXTENDED_LOAD_TYPES.key?(opcode) || EXTENDED_GLOBAL_GET_TYPES.key?(opcode)))
          instruction[1]
        else
          -1
        end
      end

      # @rbs opcode: Integer
      # @rbs return: bool
      def self.may_throw?(opcode)
        opcode == CALL || opcode == CALL_INDIRECT || opcode == THROW || opcode == THROW_REF
      end

      # @rbs opcode: Integer
      # @rbs return: bool
      def self.may_trap?(opcode)
        opcode == TRAP || opcode == CALL_INDIRECT || opcode == THROW_REF || (opcode >= I32_DIV_S && opcode <= I32_REM_U) ||
          (opcode >= I32_LOAD && opcode <= I32_STORE16) || memory_site?(opcode) ||
          (opcode >= I32_TRUNC_F32_S && opcode <= I64_TRUNC_F64_U) ||
          (opcode > CALL_INDIRECT && (EXTENDED_LOAD_TYPES.key?(opcode) || EXTENDED_STORE_TYPES.key?(opcode) ||
            opcode == I64_DIV_S || opcode == I64_DIV_U || opcode == I64_REM_S || opcode == I64_REM_U))
      end

      # @rbs opcode: Integer
      # @rbs return: bool
      def self.side_effect?(opcode)
        dynamic_call?(opcode) || may_throw?(opcode) || may_trap?(opcode) || reads_store?(opcode) || writes_store?(opcode) ||
          [BR, BR_IF, BR_IF_ZERO, RETURN, EH_ENTER, EH_TRIM, PROFILE].include?(opcode)
      end

      # @rbs opcode: Integer
      # @rbs return: bool
      def self.dynamic_call?(opcode)
        opcode == CALL_HOST || opcode == CALL_INDIRECT
      end

      # @rbs opcode: Integer
      # @rbs return: bool
      def self.memory_site?(opcode)
        opcode == MEMORY_INIT || opcode == MEMORY_COPY || opcode == MEMORY_FILL
      end

      # @rbs opcode: Integer
      # @rbs return: bool
      def self.reads_store?(opcode)
        opcode == GLOBAL_GET || (opcode >= I32_LOAD && opcode <= I32_LOAD16_U) ||
          opcode == MEMORY_SIZE || opcode == MEMORY_GROW || opcode == MEMORY_INIT || opcode == MEMORY_COPY ||
          (opcode > CALL_INDIRECT && (EXTENDED_GLOBAL_GET_TYPES.key?(opcode) || EXTENDED_LOAD_TYPES.key?(opcode)))
      end

      # @rbs opcode: Integer
      # @rbs return: bool
      def self.writes_store?(opcode)
        opcode == GLOBAL_SET || (opcode >= I32_STORE && opcode <= I32_STORE16) ||
          opcode == MEMORY_GROW || memory_site?(opcode) ||
          (opcode > CALL_INDIRECT && (EXTENDED_GLOBAL_SET_TYPES.key?(opcode) || EXTENDED_STORE_TYPES.key?(opcode)))
      end

      # @rbs opcode: Integer
      # @rbs return: bool
      def self.terminal?(opcode)
        [BR, RETURN, TRAP, THROW, THROW_REF].include?(opcode)
      end

      # @rbs instruction: Wardite::Efflorescence::Instruction
      # @rbs return: Integer
      def self.target_position(instruction)
        case instruction[0]
        when BR then 1
        when BR_IF, BR_IF_ZERO then 2
        else -1
        end
      end
    end

    class Tag
      attr_reader :parameter_types #: Array[Symbol]

      # @rbs parameter_types: Array[Symbol]
      def initialize(parameter_types)
        @parameter_types = parameter_types.dup.freeze
      end
    end

    class ExceptionValue
      attr_reader :tag #: Wardite::Efflorescence::Tag
      attr_reader :payload_bits #: Array[Integer]

      # @rbs tag: Wardite::Efflorescence::Tag
      # @rbs payload_bits: Array[Integer]
      def initialize(tag, payload_bits)
        @tag = tag
        @payload_bits = payload_bits.dup.freeze
        freeze
      end
    end

    class CatchTarget
      attr_reader :tag_index #: Integer
      attr_reader :payload_registers #: Array[Integer]
      attr_reader :reference_register #: Integer
      attr_accessor :target_pc #: Integer
      attr_reader :handler_depth #: Integer

      # @rbs tag_index: Integer
      # @rbs payload_registers: Array[Integer]
      # @rbs reference_register: Integer
      # @rbs pc: Integer
      # @rbs handler_depth: Integer
      def initialize(tag_index, payload_registers, reference_register, pc, handler_depth)
        @tag_index = tag_index
        @payload_registers = payload_registers.dup
        @reference_register = reference_register
        @target_pc = pc
        @handler_depth = handler_depth
      end

      # @rbs register: Integer
      # @rbs return: void
      def replace_reference_register(register)
        @reference_register = register
      end

      # @rbs return: Wardite::Efflorescence::CatchTarget
      def copy
        CatchTarget.new(@tag_index, @payload_registers, @reference_register, @target_pc, @handler_depth)
      end

      # @rbs return: Array[Integer]
      def destinations
        @reference_register < 0 ? @payload_registers.dup : @payload_registers + [@reference_register]
      end
    end

    class HandlerDescriptor
      attr_reader :clauses #: Array[Wardite::Efflorescence::CatchTarget]

      # @rbs clauses: Array[Wardite::Efflorescence::CatchTarget]
      def initialize(clauses)
        @clauses = clauses
      end

      # @rbs return: Wardite::Efflorescence::HandlerDescriptor
      def copy
        HandlerDescriptor.new(@clauses.map { |clause| clause.copy })
      end
    end

    class ThrowSite
      attr_reader :tag_index #: Integer
      attr_reader :payload_registers #: Array[Integer]

      # @rbs tag_index: Integer
      # @rbs payload_registers: Array[Integer]
      def initialize(tag_index, payload_registers)
        @tag_index = tag_index
        @payload_registers = payload_registers.dup
      end

      # @rbs return: Wardite::Efflorescence::ThrowSite
      def copy
        ThrowSite.new(@tag_index, @payload_registers)
      end
    end

    # Bulk operands stay static in the Function. Values remain in Frame registers.
    class MemorySite
      attr_reader :sources #: Array[Integer]
      attr_reader :memory_index #: Integer
      attr_reader :source_memory_index #: Integer
      attr_reader :data_index #: Integer

      # @rbs sources: Array[Integer]
      # @rbs memory_index: Integer
      # @rbs source_memory_index: Integer
      # @rbs data_index: Integer
      def initialize(sources, memory_index: 0, source_memory_index: 0, data_index: -1)
        @sources = sources.dup
        @memory_index = memory_index
        @source_memory_index = source_memory_index
        @data_index = data_index
      end

      # @rbs return: Wardite::Efflorescence::MemorySite
      def copy
        MemorySite.new(@sources, memory_index: @memory_index, source_memory_index: @source_memory_index, data_index: @data_index)
      end
    end

    # A small wrapper keeps operand reads monomorphic even when a compiler
    # represents the outer instruction table as a generic object array.
    class Instruction
      attr_reader :operands #: Array[Integer]

      # @rbs operands: Array[Integer]
      def initialize(operands)
        @operands = operands
      end

      # @rbs index: Integer
      # @rbs return: Integer
      def [](index)
        # Keep generic CFG callbacks from widening native operand/PC reads.
        Integer(@operands.fetch(index))
      end

      # @rbs index: Integer
      # @rbs value: Integer
      # @rbs return: Integer
      def []=(index, value)
        @operands[index] = value
      end

      # @rbs return: Integer
      def size
        @operands.size
      end

      # @rbs return: Wardite::Efflorescence::Instruction
      def copy
        Instruction.new(@operands.dup)
      end
    end

    # Each instruction holds an integer array. Sources and destinations are slots
    # in initial_registers; constants occupy immutable, preinitialized slots.
    # This is deliberately separate from translation and execution so later
    # function-level optimization passes can consume and produce MIR.
    class Function
      attr_reader :index #: Integer
      attr_reader :pool_index #: Integer
      attr_reader :parameter_types #: Array[Symbol]
      attr_reader :result_types #: Array[Symbol]
      attr_reader :local_count #: Integer
      attr_reader :instructions #: Array[Wardite::Efflorescence::Instruction]
      attr_reader :initial_registers #: Array[Integer]
      attr_reader :constant_registers #: Array[Integer]
      attr_reader :bytecode #: Array[Integer]
      attr_reader :register_types #: Array[Symbol]
      attr_reader :handlers #: Array[Wardite::Efflorescence::HandlerDescriptor]
      attr_reader :flat_handlers #: Array[Wardite::Efflorescence::HandlerDescriptor]
      attr_reader :throw_sites #: Array[Wardite::Efflorescence::ThrowSite]
      attr_accessor :uses_i64 #: bool
      attr_accessor :uses_float #: bool
      attr_accessor :uses_eh #: bool
      attr_accessor :uses_store #: bool
      attr_accessor :uses_dynamic_calls #: bool
      attr_reader :dynamic_sites #: Array[Wardite::Efflorescence::DynamicCallSite]
      attr_reader :memory_sites #: Array[Wardite::Efflorescence::MemorySite]
      attr_reader :calls #: Array[Wardite::Efflorescence::CallSite]

      # @rbs index: Integer
      # @rbs parameter_types: Array[Symbol]
      # @rbs result_types: Array[Symbol]
      # @rbs local_count: Integer
      # @rbs local_types: Array[Symbol]?
      # @rbs pool_index: Integer?
      def initialize(index, parameter_types, result_types, local_count, local_types: nil, pool_index: nil)
        @index = index
        @pool_index = pool_index || index
        @parameter_types = parameter_types.dup
        @result_types = result_types.dup
        @local_count = local_count
        @register_types = parameter_types + (local_types || Array.new(local_count, :i32))
        @handlers = []
        @flat_handlers = []
        @throw_sites = []
        @memory_sites = []
        @uses_store = false
        @uses_dynamic_calls = false
        @dynamic_sites = []
        @uses_i64 = @register_types.include?(:i64) || result_types.include?(:i64)
        @uses_float = @register_types.any? { |type| FloatBits.float_type?(type) } || result_types.any? { |type| FloatBits.float_type?(type) }
        @uses_eh = @register_types.include?(:exnref)
        @instructions = []
        @initial_registers = Array.new(parameter_types.size + local_count, 0)
        @constant_registers = []
        @bytecode = []
        @calls = []
      end

      # @rbs return: Integer
      def register_count
        @initial_registers.size
      end

      # @rbs return: Integer
      def parameter_count
        @parameter_types.size
      end

      # @rbs index: Integer
      # @rbs return: Integer
      def initial_value(index)
        @initial_registers.fetch(index)
      end

      # @rbs value: Integer
      # @rbs return: Integer
      # @rbs type: Symbol
      def allocate_register(value, type: :i32)
        slot = @initial_registers.size
        @initial_registers << value
        @uses_i64 = true if type == :i64
        @uses_float = true if FloatBits.float_type?(type)
        @register_types << type
        slot
      end

      # @rbs value: Integer
      # @rbs return: Integer
      # @rbs type: Symbol
      def allocate_constant(value, type: :i32)
        slot = allocate_register(value, type: type)
        @constant_registers << slot
        slot
      end

      # @rbs instructions: Array[Wardite::Efflorescence::Instruction]
      # @rbs return: void
      def replace_instructions(instructions)
        @instructions = instructions
      end

      # @rbs code: Array[Integer]
      # @rbs calls: Array[Wardite::Efflorescence::CallSite]
      # @rbs return: void
      def install_code(code, calls)
        @bytecode = code
        @calls = calls
      end

      # Keep the element type at the array boundary. In particular, fetch on
      # an object array makes Spinel fall back to a generic boxed container.
      # @rbs index: Integer
      # @rbs return: Wardite::Efflorescence::CallSite
      def call_site(index)
        @calls[index] || raise(Wardite::EvalError, "invalid MIR call site")
      end

      # @rbs return: Integer
      def call_site_count
        @calls.length
      end

      # @rbs site: Wardite::Efflorescence::CallSite
      # @rbs return: void
      def add_call_site(site)
        @calls.push(site)
        nil
      end

      # @rbs index: Integer
      # @rbs return: Wardite::Efflorescence::MemorySite
      def memory_site(index)
        raise Wardite::EvalError, "invalid MIR memory site" if index < 0
        @memory_sites[index] || raise(Wardite::EvalError, "invalid MIR memory site")
      end

      # @rbs index: Integer
      # @rbs return: Wardite::Efflorescence::DynamicCallSite
      def dynamic_site(index)
        raise TranslationError, "invalid MIR dynamic call site" if index < 0
        @dynamic_sites[index] || raise(TranslationError, "invalid MIR dynamic call site")
      end

      # All PC consumers (rewrites, profiling, lowering) share this enumeration.
      # @rbs mapping: Array[Integer]
      # @rbs return: void
      def remap_targets!(mapping)
        @instructions.each do |instruction|
          position = Opcode.target_position(instruction)
          instruction[position] = mapping.fetch(instruction[position]) if position >= 0
        end
        remap_handler_targets!(@handlers, mapping)
      end

      # @rbs handlers: Array[Wardite::Efflorescence::HandlerDescriptor]
      # @rbs mapping: Array[Integer]
      # @rbs return: void
      def remap_handler_targets!(handlers, mapping)
        handlers.each do |handler|
          handler.clauses.each { |clause| clause.target_pc = mapping.fetch(clause.target_pc) }
        end
      end

      # @rbs return: void
      def lower_handlers
        @flat_handlers = @handlers.map { |handler| handler.copy }
        return if @flat_handlers.empty?
        mapping = (0..@instructions.size).map { |pc| pc * Lowerer::WIDTH }
        remap_handler_targets!(@flat_handlers, mapping)
      end

      # Rename MIR references, including operands stored outside instructions.
      # The caller supplies existing same-typed slots and validates the result.
      # @rbs mapping: Array[Integer]
      # @rbs return: void
      def replace_register_references!(mapping)
        @instructions.each do |instruction|
          Opcode.read_positions(instruction).each do |position|
            instruction[position] = mapping.fetch(instruction[position])
          end
          destination = Opcode.destination(instruction)
          instruction[1] = mapping.fetch(destination) if destination >= 0
        end
        @throw_sites.each { |site| site.payload_registers.map! { |register| mapping.fetch(register) } }
        @memory_sites.each { |site| site.sources.map! { |register| mapping.fetch(register) } }
        @dynamic_sites.each { |site| site.arguments.map! { |register| mapping.fetch(register) } }
        @handlers.each do |handler|
          handler.clauses.each do |clause|
            clause.payload_registers.map! { |register| mapping.fetch(register) }
            if clause.reference_register >= 0
              clause.replace_reference_register(mapping.fetch(clause.reference_register))
            end
          end
        end
      end

      # @rbs instruction: Wardite::Efflorescence::Instruction
      # @rbs return: Array[Integer]
      def reads(instruction)
        result = Opcode.read_positions(instruction).map { |position| instruction[position] }
        result += @throw_sites.fetch(instruction[1]).payload_registers if instruction[0] == Opcode::THROW
        result += memory_site(instruction[1]).sources if Opcode.memory_site?(instruction[0])
        result += dynamic_site(instruction[2]).arguments if Opcode.dynamic_call?(instruction[0])
        result
      end

      # @rbs return: Wardite::Efflorescence::Function
      def copy
        result = Function.new(@index, @parameter_types, @result_types, @local_count, local_types: @register_types[@parameter_types.size, @local_count], pool_index: @pool_index)
        result.uses_i64 = @uses_i64
        result.uses_float = @uses_float
        result.uses_eh = @uses_eh
        result.uses_store = @uses_store
        result.uses_dynamic_calls = @uses_dynamic_calls
        @dynamic_sites.each { |site| result.dynamic_sites << site.copy }
        @memory_sites.each { |site| result.memory_sites << site.copy }
        @handlers.each { |handler| result.handlers << handler.copy }
        @throw_sites.each { |site| result.throw_sites << site.copy }
        index = @parameter_types.size + @local_count
        while index < register_count
          if @constant_registers.include?(index)
            result.allocate_constant(initial_value(index), type: @register_types.fetch(index))
          else
            result.allocate_register(initial_value(index), type: @register_types.fetch(index))
          end
          index += 1
        end
        result.replace_instructions(@instructions.map { |instruction| instruction.copy })
        result
      end
    end

    class CallSite
      attr_reader :callee #: Wardite::Efflorescence::Function
      attr_reader :arguments #: Array[Integer]
      attr_reader :pool_index #: Integer

      # @rbs callee: Wardite::Efflorescence::Function
      # @rbs arguments: Array[Integer]
      def initialize(callee, arguments)
        @callee = callee
        @arguments = arguments
        @pool_index = callee.pool_index
      end

      # Keep the generic argument loop out of the interpreter's live locals.
      # The common single-argument path copies directly from the CALL operand.
      # @rbs target: Array[Integer]
      # @rbs source: Array[Integer]
      # @rbs return: void
      def copy_arguments(target, source)
        argument = 0
        count = @arguments.size
        while argument < count
          target[argument] = source[@arguments.fetch(argument)]
          argument += 1
        end
      end
    end

    class DynamicCallSite
      attr_reader :host_index #: Integer
      attr_reader :table_index #: Integer
      attr_reader :arguments #: Array[Integer]
      attr_reader :parameter_types #: Array[Symbol]
      attr_reader :result_types #: Array[Symbol]

      # @rbs host_index: Integer
      # @rbs arguments: Array[Integer]
      # @rbs parameter_types: Array[Symbol]
      # @rbs result_types: Array[Symbol]
      # @rbs table_index: Integer
      def initialize(host_index, arguments, parameter_types, result_types, table_index: -1)
        @host_index = host_index
        @table_index = table_index
        @arguments = [] #: Array[Integer]
        @arguments.replace(arguments)
        @parameter_types = parameter_types.dup
        @result_types = result_types.dup
      end

      # @rbs return: Wardite::Efflorescence::DynamicCallSite
      def copy
        DynamicCallSite.new(@host_index, @arguments, @parameter_types, @result_types, table_index: @table_index)
      end
    end

    # @rbs!
    #   interface _WasiCallable
    #     def call: (Wardite::Store, Array[Integer], Array[Integer]?) -> Integer?
    #   end

    class HostFunction
      attr_reader :external #: Wardite::ExternalFunction
      attr_reader :entry #: Wardite::Efflorescence::FunctionEntry
      attr_reader :callable #: Wardite::_WasmCallable
      attr_reader :typed_abi #: bool
      attr_reader :unboxed_wasi #: Wardite::Efflorescence::_WasiCallable?

      # @rbs external: Wardite::ExternalFunction
      # @rbs entry: Wardite::Efflorescence::FunctionEntry
      # @rbs callable: Wardite::_WasmCallable
      # @rbs unboxed_wasi: Wardite::Efflorescence::_WasiCallable?
      def initialize(external, entry, callable, unboxed_wasi)
        @external = external
        @entry = entry
        @callable = callable
        @typed_abi = entry.parameter_types.any? { |type| type != :i32 } || entry.result_types.any? { |type| type != :i32 }
        @unboxed_wasi = unboxed_wasi
      end

      # @rbs return: Wardite::Efflorescence::HostFunction
      def copy
        HostFunction.new(@external, @entry.copy, @callable, @unboxed_wasi)
      end
    end

    class FunctionEntry
      attr_reader :kind #: Symbol
      attr_reader :parameter_types #: Array[Symbol]
      attr_reader :result_types #: Array[Symbol]
      attr_reader :defined_index #: Integer
      attr_reader :host_index #: Integer

      # @rbs kind: Symbol
      # @rbs parameter_types: Array[Symbol]
      # @rbs result_types: Array[Symbol]
      # @rbs defined_index: Integer
      # @rbs host_index: Integer
      def initialize(kind, parameter_types, result_types, defined_index, host_index)
        @kind = kind
        @parameter_types = parameter_types.dup
        @result_types = result_types.dup
        @defined_index = defined_index
        @host_index = host_index
      end

      # @rbs params: Array[Symbol]
      # @rbs results: Array[Symbol]
      # @rbs label: String
      # @rbs return: void
      def self.check_signature(params, results, label)
        unless results.size <= 1 && params.all? { |type| numeric_type?(type) } &&
            results.all? { |type| numeric_type?(type) }
          raise UnsupportedFeature, "Efflorescence: #{label} requires a numeric signature with at most one result (i32/i64/f32/f64)"
        end
      end

      # @rbs type: Symbol
      # @rbs return: bool
      def self.numeric_type?(type)
        type == :i32 || type == :i64 || FloatBits.float_type?(type)
      end

      # @rbs return: Wardite::Efflorescence::FunctionEntry
      def copy
        FunctionEntry.new(@kind, @parameter_types, @result_types, @defined_index, @host_index)
      end
    end

    class IR
      attr_reader :functions #: Array[Wardite::Efflorescence::Function]
      attr_reader :entries #: Array[Wardite::Efflorescence::FunctionEntry]
      attr_reader :hosts #: Array[Wardite::Efflorescence::HostFunction]

      # @rbs functions: Array[Wardite::Efflorescence::Function]
      # @rbs entries: Array[Wardite::Efflorescence::FunctionEntry]?
      # @rbs hosts: Array[Wardite::Efflorescence::HostFunction]
      def initialize(functions, entries: nil, hosts: [])
        @functions = functions
        @hosts = hosts
        @entries = entries || functions.map do |function|
          FunctionEntry.new(:defined, function.parameter_types, function.result_types, function.pool_index, -1)
        end
      end

      # @rbs index: Integer
      # @rbs return: Wardite::Efflorescence::FunctionEntry
      def entry_at(index)
        raise Wardite::EvalError, "invalid MIR function index #{index}" if index < 0
        @entries[index] || raise(Wardite::EvalError, "invalid MIR function index #{index}")
      end

      # @rbs index: Integer
      # @rbs return: Wardite::Efflorescence::Function
      def function_at(index)
        entry = entry_at(index)
        raise Wardite::EvalError, "MIR function #{index} is not defined" unless entry.kind == :defined
        defined_at(entry.defined_index)
      end

      # @rbs index: Integer
      # @rbs return: Wardite::Efflorescence::Function
      def defined_at(index)
        @functions[index] || raise(Wardite::EvalError, "invalid MIR defined index #{index}")
      end

      # @rbs return: Wardite::Efflorescence::IR
      def copy
        IR.new(@functions.map { |function| function.copy }, entries: @entries.map { |entry| entry.copy },
          hosts: @hosts.map { |host| host.copy })
      end
    end

    class Frame
      attr_reader :function #: Wardite::Efflorescence::Function
      attr_reader :pool_index #: Integer
      # Numeric registers hold unsigned 32-bit or signed 64-bit carriers.
      attr_reader :registers #: Array[Integer]
      attr_reader :exception_registers #: Array[Wardite::Efflorescence::ExceptionValue?]
      attr_reader :handlers #: Array[Integer]
      attr_reader :return_register #: Integer
      attr_accessor :pc #: Integer

      # @rbs function: Wardite::Efflorescence::Function
      # @rbs return_register: Integer
      def initialize(function, return_register)
        @function = function
        @pool_index = function.pool_index
        # Constants are initialized once and never written by verified MIR.
        # Copying the template also avoids zero-filling and then overwriting
        # every slot in a second loop on a newly allocated frame.
        @uses_eh = function.uses_eh
        @registers = function.initial_registers.dup
        @exception_registers = function.register_types.include?(:exnref) ? Array.new(function.register_count, nil) : []
        @handlers = []
        @local_start = function.parameter_count
        @local_end = @local_start + function.local_count
        @return_register = return_register
        @pc = 0
      end

      # @rbs return: void
      def clear_references
        @exception_registers.fill(nil)
        @handlers.clear
      end

      # @rbs depth: Integer
      # @rbs return: void
      def trim_handlers(depth)
        @handlers.pop while @handlers.size > depth
      end

      # @rbs return_register: Integer
      # @rbs return: void
      def reset(return_register)
        clear_references if @uses_eh
        # CALL overwrites all parameters; Wasm initializes only non-parameter
        # locals to zero. RegisterValidation proves that every temporary is
        # written before it is read, including across joins and backedges.
        index = @local_start
        while index < @local_end
          @registers[index] = 0
          index += 1
        end
        @return_register = return_register
        @pc = 0
      end
    end

    # An invocation owns its pools. Active recursive frames never enter the
    # free list, and overlapping/reentrant public calls cannot share a frame.
    class FramePool
      attr_reader :created #: Integer

      # @rbs function: Wardite::Efflorescence::Function
      # @rbs reuse: bool
      def initialize(function, reuse)
        @function = function
        @reuse = reuse
        @clear_references = function.uses_eh
        @free = [] #: Array[Wardite::Efflorescence::Frame]
        @created = 0
      end

      # @rbs destination: Integer
      # @rbs return: Wardite::Efflorescence::Frame
      def acquire(destination)
        if @reuse
          frame = @free.pop
          if frame
            frame.reset(destination)
            return frame
          end
        end
        @created += 1
        Frame.new(@function, destination)
      end

      # @rbs frame: Wardite::Efflorescence::Frame
      # @rbs return: void
      def release(frame)
        frame.clear_references if @clear_references
        @free << frame if @reuse
      end
    end
  end
end
