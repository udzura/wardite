# frozen_string_literal: true
# rbs_inline: enabled

module Wardite
  module Efflorescence
    # The operand/control stacks exist only during translation. Execution uses
    # typed register banks, absolute PCs and explicit per-frame handler stacks.
    class Translator
      class Control
        attr_reader :kind #: Symbol
        attr_reader :entry_stack #: Array[Integer]
        attr_reader :start_pc #: Integer
        attr_reader :result_types #: Array[Symbol]
        attr_reader :result_registers #: Array[Integer]
        attr_reader :patches #: Array[Integer]
        attr_reader :catch_patches #: Array[Wardite::Efflorescence::CatchTarget]
        attr_reader :handler_depth #: Integer
        attr_reader :entry_reachable #: bool
        attr_accessor :polymorphic #: bool
        attr_accessor :has_branch #: bool
        attr_accessor :false_patch #: Integer
        attr_accessor :else_seen #: bool
        attr_accessor :then_reachable #: bool

        # @rbs kind: Symbol
        # @rbs entry_stack: Array[Integer]
        # @rbs start_pc: Integer
        # @rbs result_types: Array[Symbol]
        # @rbs result_registers: Array[Integer]
        # @rbs handler_depth: Integer
        # @rbs reachable: bool
        def initialize(kind, entry_stack, start_pc, result_types, result_registers, handler_depth, reachable)
          @kind, @entry_stack, @start_pc = kind, entry_stack.dup, start_pc
          @result_types, @result_registers = result_types, result_registers
          @handler_depth, @entry_reachable = handler_depth, reachable
          @patches, @catch_patches = [], []
          @has_branch, @else_seen, @then_reachable = false, false, false
          @false_patch = -1
          @polymorphic = false
        end
      end

      BINARY = {
        i32_add: Opcode::I32_ADD, i32_sub: Opcode::I32_SUB, i32_mul: Opcode::I32_MUL,
        i32_xor: Opcode::I32_XOR, i32_shl: Opcode::I32_SHL, i32_shr_u: Opcode::I32_SHR_U,
        i32_eq: Opcode::I32_EQ, i32_ne: Opcode::I32_NE, i32_lts: Opcode::I32_LTS,
        i32_ltu: Opcode::I32_LTU, i32_gts: Opcode::I32_GTS, i32_gtu: Opcode::I32_GTU,
        i32_les: Opcode::I32_LES, i32_leu: Opcode::I32_LEU, i32_ges: Opcode::I32_GES,
        i32_geu: Opcode::I32_GEU, i32_div_s: Opcode::I32_DIV_S, i32_div_u: Opcode::I32_DIV_U,
        i32_rem_s: Opcode::I32_REM_S, i32_rem_u: Opcode::I32_REM_U,
        i32_and: Opcode::I32_AND, i32_or: Opcode::I32_OR, i32_shr_s: Opcode::I32_SHR_S,
        i32_rotl: Opcode::I32_ROTL, i32_rotr: Opcode::I32_ROTR
      }.freeze
      UNARY = { i32_eqz: Opcode::I32_EQZ, i32_clz: Opcode::I32_CLZ,
                i32_ctz: Opcode::I32_CTZ, i32_popcnt: Opcode::I32_POPCNT,
                i32_extend8_s: Opcode::I32_EXTEND8_S, i32_extend16_s: Opcode::I32_EXTEND16_S }.freeze

      I64_ALU = {
        i64_eqz: Opcode::I64_EQZ,
        i32_wrap_i64: Opcode::I32_WRAP_I64,
        i64_eq: Opcode::I64_EQ,
        i64_ne: Opcode::I64_NE,
        i64_lts: Opcode::I64_LTS,
        i64_ltu: Opcode::I64_LTU,
        i64_gts: Opcode::I64_GTS,
        i64_gtu: Opcode::I64_GTU,
        i64_les: Opcode::I64_LES,
        i64_leu: Opcode::I64_LEU,
        i64_ges: Opcode::I64_GES,
        i64_geu: Opcode::I64_GEU,
        i64_clz: Opcode::I64_CLZ,
        i64_ctz: Opcode::I64_CTZ,
        i64_popcnt: Opcode::I64_POPCNT,
        i64_extend8_s: Opcode::I64_EXTEND8_S,
        i64_extend16_s: Opcode::I64_EXTEND16_S,
        i64_extend32_s: Opcode::I64_EXTEND32_S,
        i64_extend_i32_s: Opcode::I64_EXTEND_I32_S,
        i64_extend_i32_u: Opcode::I64_EXTEND_I32_U,
        i64_and: Opcode::I64_AND,
        i64_or: Opcode::I64_OR,
        i64_xor: Opcode::I64_XOR,
        i64_shl: Opcode::I64_SHL,
        i64_shr_s: Opcode::I64_SHR_S,
        i64_shr_u: Opcode::I64_SHR_U,
        i64_rotl: Opcode::I64_ROTL,
        i64_rotr: Opcode::I64_ROTR,
        i64_add: Opcode::I64_ADD,
        i64_sub: Opcode::I64_SUB,
        i64_mul: Opcode::I64_MUL,
        i64_div_s: Opcode::I64_DIV_S,
        i64_div_u: Opcode::I64_DIV_U,
        i64_rem_s: Opcode::I64_REM_S,
        i64_rem_u: Opcode::I64_REM_U,
      }.freeze

      # Natural alignment exponents; alignment is a hint, not an address rule.
      FLOAT_ALU = {
        f32_eq: Opcode::F32_EQ,
        f32_ne: Opcode::F32_NE,
        f32_lt: Opcode::F32_LT,
        f32_gt: Opcode::F32_GT,
        f32_le: Opcode::F32_LE,
        f32_ge: Opcode::F32_GE,
        f32_abs: Opcode::F32_ABS,
        f32_neg: Opcode::F32_NEG,
        f32_ceil: Opcode::F32_CEIL,
        f32_floor: Opcode::F32_FLOOR,
        f32_trunc: Opcode::F32_TRUNC,
        f32_nearest: Opcode::F32_NEAREST,
        f32_sqrt: Opcode::F32_SQRT,
        f32_add: Opcode::F32_ADD,
        f32_sub: Opcode::F32_SUB,
        f32_mul: Opcode::F32_MUL,
        f32_div: Opcode::F32_DIV,
        f32_min: Opcode::F32_MIN,
        f32_max: Opcode::F32_MAX,
        f32_copysign: Opcode::F32_COPYSIGN,
        f64_eq: Opcode::F64_EQ,
        f64_ne: Opcode::F64_NE,
        f64_lt: Opcode::F64_LT,
        f64_gt: Opcode::F64_GT,
        f64_le: Opcode::F64_LE,
        f64_ge: Opcode::F64_GE,
        f64_abs: Opcode::F64_ABS,
        f64_neg: Opcode::F64_NEG,
        f64_ceil: Opcode::F64_CEIL,
        f64_floor: Opcode::F64_FLOOR,
        f64_trunc: Opcode::F64_TRUNC,
        f64_nearest: Opcode::F64_NEAREST,
        f64_sqrt: Opcode::F64_SQRT,
        f64_add: Opcode::F64_ADD,
        f64_sub: Opcode::F64_SUB,
        f64_mul: Opcode::F64_MUL,
        f64_div: Opcode::F64_DIV,
        f64_min: Opcode::F64_MIN,
        f64_max: Opcode::F64_MAX,
        f64_copysign: Opcode::F64_COPYSIGN,
        i32_trunc_f32_s: Opcode::I32_TRUNC_F32_S,
        i32_trunc_f32_u: Opcode::I32_TRUNC_F32_U,
        i32_trunc_f64_s: Opcode::I32_TRUNC_F64_S,
        i32_trunc_f64_u: Opcode::I32_TRUNC_F64_U,
        i64_trunc_f32_s: Opcode::I64_TRUNC_F32_S,
        i64_trunc_f32_u: Opcode::I64_TRUNC_F32_U,
        i64_trunc_f64_s: Opcode::I64_TRUNC_F64_S,
        i64_trunc_f64_u: Opcode::I64_TRUNC_F64_U,
        i32_trunc_sat_f32_s: Opcode::I32_TRUNC_SAT_F32_S,
        i32_trunc_sat_f32_u: Opcode::I32_TRUNC_SAT_F32_U,
        i32_trunc_sat_f64_s: Opcode::I32_TRUNC_SAT_F64_S,
        i32_trunc_sat_f64_u: Opcode::I32_TRUNC_SAT_F64_U,
        i64_trunc_sat_f32_s: Opcode::I64_TRUNC_SAT_F32_S,
        i64_trunc_sat_f32_u: Opcode::I64_TRUNC_SAT_F32_U,
        i64_trunc_sat_f64_s: Opcode::I64_TRUNC_SAT_F64_S,
        i64_trunc_sat_f64_u: Opcode::I64_TRUNC_SAT_F64_U,
        f32_convert_i32_s: Opcode::F32_CONVERT_I32_S,
        f32_convert_i32_u: Opcode::F32_CONVERT_I32_U,
        f32_convert_i64_s: Opcode::F32_CONVERT_I64_S,
        f32_convert_i64_u: Opcode::F32_CONVERT_I64_U,
        f64_convert_i32_s: Opcode::F64_CONVERT_I32_S,
        f64_convert_i32_u: Opcode::F64_CONVERT_I32_U,
        f64_convert_i64_s: Opcode::F64_CONVERT_I64_S,
        f64_convert_i64_u: Opcode::F64_CONVERT_I64_U,
        f32_demote_f64: Opcode::F32_DEMOTE_F64,
        f64_promote_f32: Opcode::F64_PROMOTE_F32,
        i32_reinterpret_f32: Opcode::I32_REINTERPRET_F32,
        i64_reinterpret_f64: Opcode::I64_REINTERPRET_F64,
        f32_reinterpret_i32: Opcode::F32_REINTERPRET_I32,
        f64_reinterpret_i64: Opcode::F64_REINTERPRET_I64,
      }.freeze #: Hash[Symbol, Integer]

      MEMORY_WIDTHS = { i32_load: 2, i32_load8_s: 0, i32_load8_u: 0,
                        i32_load16_s: 1, i32_load16_u: 1,
                        i32_store: 2, i32_store8: 0, i32_store16: 1,
                        i64_load: 3, i64_load8_s: 0, i64_load8_u: 0,
                        i64_load16_s: 1, i64_load16_u: 1, i64_load32_s: 2, i64_load32_u: 2,
                        i64_store: 3, i64_store8: 0, i64_store16: 1, i64_store32: 2,
                        f32_load: 2, f32_store: 2, f64_load: 3, f64_store: 3 }.freeze
      MEMORY_OPCODES = { i32_load: Opcode::I32_LOAD, i32_load8_s: Opcode::I32_LOAD8_S,
                         i32_load8_u: Opcode::I32_LOAD8_U, i32_load16_s: Opcode::I32_LOAD16_S,
                         i32_load16_u: Opcode::I32_LOAD16_U, i32_store: Opcode::I32_STORE,
                         i32_store8: Opcode::I32_STORE8, i32_store16: Opcode::I32_STORE16,
                         i64_load: Opcode::I64_LOAD,
                         i64_load8_s: Opcode::I64_LOAD8_S,
                         i64_load8_u: Opcode::I64_LOAD8_U,
                         i64_load16_s: Opcode::I64_LOAD16_S,
                         i64_load16_u: Opcode::I64_LOAD16_U,
                         i64_load32_s: Opcode::I64_LOAD32_S,
                         i64_load32_u: Opcode::I64_LOAD32_U,
                         i64_store: Opcode::I64_STORE,
                         i64_store8: Opcode::I64_STORE8,
                         i64_store16: Opcode::I64_STORE16,
                         i64_store32: Opcode::I64_STORE32,
                         f32_load: Opcode::F32_LOAD, f32_store: Opcode::F32_STORE,
                         f64_load: Opcode::F64_LOAD, f64_store: Opcode::F64_STORE }.freeze
      STORE_CODES = (MEMORY_WIDTHS.keys + %i[global_get global_set memory_size memory_grow memory_init memory_copy memory_fill]).freeze

      # @rbs @instance: Wardite::Instance
      # @rbs @entries: Array[Wardite::Efflorescence::FunctionEntry]
      # @rbs @stack: Array[Integer]
      # @rbs @controls: Array[Wardite::Efflorescence::Translator::Control]
      # @rbs @constants: Hash[Integer, Integer]
      # @rbs @i64_constants: Hash[Integer, Integer]?
      # @rbs @f32_constants: Hash[Integer, Integer]?
      # @rbs @f64_constants: Hash[Integer, Integer]?
      # @rbs @function: Wardite::Efflorescence::Function
      # @rbs @reachable: bool
      # @rbs @wasm_pc: Integer
      # @rbs @handler_depth: Integer

      # @rbs instance: Wardite::Instance
      def initialize(instance)
        @instance = instance
        @entries = []
        @stack, @controls, @constants = [], [], {}
        @i64_constants = nil
        @f32_constants = nil
        @f64_constants = nil
        @reachable, @wasm_pc, @handler_depth = true, 0, 0
        @function = Function.new(0, [], [], 0)
      end

      # @rbs return: Wardite::Efflorescence::IR
      def link
        hosts = [] #: Array[Wardite::Efflorescence::HostFunction]
        defined_count = 0
        entries = @instance.store.funcs.map do |function|
          if function.is_a?(Wardite::ExternalFunction)
            entry = FunctionEntry.new(:host, function.callsig, function.retsig, -1, hosts.size)
            callable = function.callable #: Wardite::_WasmCallable & Object
            unless callable.respond_to?(:call)
              raise Wardite::LoadError, "import #{function.name} is not callable"
            end
            unboxed_wasi = nil
            if RUBY_ENGINE != "spinel"
              wasi = @instance.wasi
              if wasi && wasi.equal?(function.target_module) && wasi.is_a?(Wardite::Efflorescence::WasiSnapshotPreview1)
                unboxed_wasi = Wardite::Efflorescence::WasiSnapshotPreview1.unboxed_callable(wasi, function)
              end
            end
            hosts << HostFunction.new(function, entry, callable, unboxed_wasi)
            entry
          else
            entry = FunctionEntry.new(:defined, function.callsig, function.retsig, defined_count, -1)
            defined_count += 1
            entry
          end
        end
        IR.new([], entries: entries, hosts: hosts)
      end

      # @rbs linked: Wardite::Efflorescence::IR
      # @rbs return: Wardite::Efflorescence::IR
      def translate(linked = link)
        @entries = linked.entries
        functions = [] #: Array[Wardite::Efflorescence::Function]
        @instance.store.funcs.each_with_index do |function, index|
          if function.is_a?(Wardite::WasmFunction)
            functions << translate_function(function, index, functions.size)
          end
        end
        IR.new(functions, entries: @entries, hosts: linked.hosts)
      end

      # @rbs wasm: Wardite::WasmFunction
      # @rbs index: Integer
      # @rbs pool_index: Integer
      # @rbs return: Wardite::Efflorescence::Function
      def translate_function(wasm, index, pool_index)
        FunctionEntry.check_signature(wasm.callsig, wasm.retsig, "function #{index}")
        unless wasm.locals_type.all? { |type| FunctionEntry.numeric_type?(type) || type == :exnref }
          raise UnsupportedFeature, "Efflorescence: function #{index} has unsupported locals"
        end
        locals = [] #: Array[Symbol]
        wasm.locals_type.each_with_index { |type, i| wasm.locals_count.fetch(i).times { locals << type } }
        @function = Function.new(index, wasm.callsig, wasm.retsig, locals.size, local_types: locals, pool_index: pool_index)
        @stack, @controls, @constants = [], [], {}
        @i64_constants = nil
        @f32_constants = nil
        @f64_constants = nil
        @reachable, @handler_depth = true, 0
        @controls << new_control(:function, wasm.retsig)
        wasm.body.each_with_index do |instruction, pc|
          @wasm_pc = pc
          fail_translation("instruction after function end") if @controls.empty?
          code, operands = instruction[1], instruction[2]
          validate_store_instruction(code, operands) if STORE_CODES.include?(code)
          if BINARY.key?(code)
            right, left = pop_typed(:i32), pop_typed(:i32)
            dst = register
            emit([BINARY.fetch(code), dst, left, right]) if @reachable
            @stack << dst
            next
          elsif UNARY.key?(code)
            source = pop_typed(:i32)
            dst = register
            emit([UNARY.fetch(code), dst, source]) if @reachable
            @stack << dst
            next
          end
          case code
          when :block, :loop, :if, :try_table
            block = operands[0]
            fail_translation("expected block signature") unless block.is_a?(Wardite::Block)
            unless block.parameter_types.empty? && block.result_types.all? { |type| FunctionEntry.numeric_type?(type) || type == :exnref }
              raise UnsupportedFeature, context("block parameters and unsupported block result types are not supported")
            end
            condition = code == :if ? pop_typed(:i32) : -1
            snapshot_locals if @reachable
            control = new_control(code, block.result_types)
            if code == :if && @reachable
              control.false_patch = emit([Opcode::BR_IF_ZERO, condition, -1])
            elsif code == :try_table
              @function.uses_eh = true
              clauses = operands[1]
              fail_translation("expected catch clauses") unless clauses.is_a?(Wardite::OperandVector)
              descriptor = make_handler(clauses.entries)
              id = @function.handlers.size
              @function.handlers << descriptor
              emit([Opcode::EH_ENTER, id]) if @reachable
              @handler_depth += 1
            end
            @function.uses_eh = true if block.result_types.include?(:exnref)
            @controls << control
          when :else
            else_control
          when :end
            end_control
          when :i32_load, :i32_load8_s, :i32_load8_u, :i32_load16_s, :i32_load16_u,
               :i32_store, :i32_store8, :i32_store16,
               :i64_load, :i64_load8_s, :i64_load8_u, :i64_load16_s, :i64_load16_u, :i64_load32_s, :i64_load32_u,
               :i64_store, :i64_store8, :i64_store16, :i64_store32,
               :f32_load, :f64_load, :f32_store, :f64_store
            opcode = MEMORY_OPCODES.fetch(code)
            offset = integer_operand(operands[1])
            store_type = Opcode::EXTENDED_STORE_TYPES[opcode]
            type = store_type || Opcode::EXTENDED_LOAD_TYPES[opcode] || :i32
            @function.uses_i64 = true if type == :i64
            @function.uses_float = true if FloatBits.float_type?(type)
            if store_type || code == :i32_store || code == :i32_store8 || code == :i32_store16
              value = pop_typed(type)
              address = pop_typed(:i32)
              emit([opcode, value, address, offset]) if @reachable
            else
              address = pop_typed(:i32)
              dst = register(type)
              emit([opcode, dst, address, offset]) if @reachable
              @stack << dst
            end
          when :memory_init, :memory_copy, :memory_fill
            length, source, destination = pop_typed(:i32), pop_typed(:i32), pop_typed(:i32)
            next unless @reachable
            data_index = code == :memory_init ? integer_operand(operands[0]) : -1
            site = MemorySite.new([destination, source, length], data_index: data_index)
            id = @function.memory_sites.size
            @function.memory_sites << site
            opcode = case code
                     when :memory_init then Opcode::MEMORY_INIT
                     when :memory_copy then Opcode::MEMORY_COPY
                     else Opcode::MEMORY_FILL
                     end
            emit([opcode, id])
          when :memory_size, :memory_grow
            source = code == :memory_grow ? pop_typed(:i32) : -1
            dst = register
            emit(code == :memory_grow ? [Opcode::MEMORY_GROW, dst, source] : [Opcode::MEMORY_SIZE, dst]) if @reachable
            @stack << dst
          when :global_get, :global_set
            index = integer_operand(operands[0])
            type = @instance.store.globals.fetch(index).type
            @function.uses_i64 = true if type == :i64
            @function.uses_float = true if FloatBits.float_type?(type)
            if code == :global_get
              dst = register(type)
              opcode = case type
                       when :i64 then Opcode::I64_GLOBAL_GET
                       when :f32 then Opcode::F32_GLOBAL_GET
                       when :f64 then Opcode::F64_GLOBAL_GET
                       else Opcode::GLOBAL_GET
                       end
              emit([opcode, dst, index]) if @reachable
              @stack << dst
            else
              source = pop_typed(type)
              opcode = case type
                       when :i64 then Opcode::I64_GLOBAL_SET
                       when :f32 then Opcode::F32_GLOBAL_SET
                       when :f64 then Opcode::F64_GLOBAL_SET
                       else Opcode::GLOBAL_SET
                       end
              emit([opcode, index, source]) if @reachable
            end
          when :local_get, :local_set, :local_tee
            local = integer_operand(operands[0])
            fail_translation("invalid local index #{local}") unless local >= 0 && local < @function.parameter_count + @function.local_count
            if code == :local_get
              @stack << local
            else
              source = pop_typed(type_of(local))
              if @reachable
                preserve_local(local)
                copy_value(local, source) unless local == source
              end
              @stack << local if code == :local_tee
            end
          when :i32_const, :i64_const
            immediate = integer_operand(operands[0])
            if code == :i64_const
              @function.uses_i64 = true
              @stack << constant(I64Arithmetic.normalize(immediate), :i64)
            else
              @stack << constant(immediate & 0xffffffff)
            end
          when :f32_const, :f64_const
            operand = operands[0]
            type = code == :f32_const ? :f32 : :f64
            unless operand.is_a?(FloatImmediate) && operand.type == type
              fail_translation("invalid float immediate")
            end
            @stack << constant(operand.bits, type)
          when :br, :br_if
            target = label(integer_operand(operands[0]))
            condition = code == :br_if ? pop_typed(:i32) : -1
            types = label_types(target)
            sources = top_values(types)
            unless @reachable
              if code == :br
                mark_unreachable
              else
                types.size.times { pop_value }
                @stack.concat(target.result_registers) unless target.kind == :loop
              end
              next
            end
            if code == :br_if && (types.size > 0 || @handler_depth != target.handler_depth)
              skip = emit([Opcode::BR_IF_ZERO, condition, -1])
              branch(target, sources)
              patch(skip, @function.instructions.size)
            else
              branch(target, sources, condition)
            end
            mark_unreachable if code == :br
          when :br_table
            depths = operands[0]
            fail_translation("expected branch table") unless depths.is_a?(Wardite::OperandVector)
            targets = depths.entries.map { |depth| label(depth) }
            default = label(integer_operand(operands[1]))
            types = label_types(default)
            fail_translation("inconsistent br_table label types") unless targets.all? { |target| label_types(target) == types }
            selector = pop_typed(:i32)
            sources = top_values(types)
            unless @reachable
              mark_unreachable
              next
            end
            targets.each_with_index do |target, i|
              comparison = register
              emit([Opcode::I32_EQ, comparison, selector, constant(i)])
              skip = emit([Opcode::BR_IF_ZERO, comparison, -1])
              branch(target, sources)
              patch(skip, @function.instructions.size)
            end
            branch(default, sources)
            mark_unreachable
          when :select
            condition, right, left = pop_typed(:i32), pop_value, pop_value
            type = right < 0 ? type_of(left) : type_of(right)
            unless (FunctionEntry.numeric_type?(type) || type == :unknown) && (left < 0 || type_of(left) == type)
              fail_translation("select requires matching integer operands")
            end
            dst = type == :unknown ? -1 : register(type)
            @stack << dst
            next unless @reachable
            copy_value(dst, right)
            skip = emit([Opcode::BR_IF_ZERO, condition, -1])
            copy_value(dst, left)
            patch(skip, @function.instructions.size)
          when :call
            index = integer_operand(operands[0])
            fail_translation("invalid call target #{index}") if index < 0
            callee = @entries[index]
            fail_translation("invalid call target #{index}") unless callee
            FunctionEntry.check_signature(callee.parameter_types, callee.result_types, "function #{index}")
            @function.uses_dynamic_calls = true if callee.kind == :host
            arguments = callee.parameter_types.reverse.map { |type| pop_typed(type) }.reverse
            dst = callee.result_types.empty? ? -1 : register(callee.result_types.fetch(0))
            @stack << dst if dst >= 0
            next unless @reachable
            if callee.kind == :host
              id = @function.dynamic_sites.size
              @function.dynamic_sites << DynamicCallSite.new(callee.host_index, arguments, callee.parameter_types, callee.result_types)
              emit([Opcode::CALL_HOST, dst, id, 0])
            else
              emit([Opcode::CALL, dst, index] + arguments)
            end
          when :call_indirect
            type_index = integer_operand(operands[0])
            table_index = integer_operand(operands[1])
            raise UnsupportedFeature, context("only call_indirect through table 0 is supported") unless table_index == 0
            table = @instance.store.tables[0]
            fail_translation("call_indirect requires funcref table 0") unless table && table.type == :funcref
            type = @instance.types[type_index] if type_index >= 0
            fail_translation("invalid indirect call type index #{type_index}") unless type
            FunctionEntry.check_signature(type.callsig, type.retsig, "type #{type_index}")
            @function.uses_dynamic_calls = true
            selector = pop_typed(:i32)
            arguments = type.callsig.reverse.map { |param| pop_typed(param) }.reverse
            dst = type.retsig.empty? ? -1 : register(type.retsig.fetch(0))
            @stack << dst if dst >= 0
            next unless @reachable
            id = @function.dynamic_sites.size
            @function.dynamic_sites << DynamicCallSite.new(-1, arguments, type.callsig, type.retsig, table_index: table_index)
            emit([Opcode::CALL_INDIRECT, dst, id, selector])
          when :throw
            tag_index = integer_operand(operands[0])
            tag = tag_at(tag_index)
            @function.uses_eh = true
            payload = tag.parameter_types.reverse.map { |type| pop_typed(type) }.reverse
            if @reachable
              id = @function.throw_sites.size
              @function.throw_sites << ThrowSite.new(tag_index, payload)
              emit([Opcode::THROW, id])
            end
            mark_unreachable
          when :throw_ref
            @function.uses_eh = true
            reference = pop_typed(:exnref)
            emit([Opcode::THROW_REF, reference]) if @reachable
            mark_unreachable
          when :return
            source = @function.result_types.empty? ? -1 : pop_typed(@function.result_types.fetch(0))
            emit([Opcode::RETURN, source]) if @reachable
            mark_unreachable
          when :unreachable
            emit([Opcode::TRAP]) if @reachable
            mark_unreachable
          when :drop
            pop_value
          when :nop
          else
            opcode = I64_ALU[code] || FLOAT_ALU[code]
            raise UnsupportedFeature, context("unsupported instruction #{code}") unless opcode
            types = Opcode.extended_alu_types(opcode) || raise(TranslationError, context("missing ALU signature"))
            if opcode >= Opcode::F32_EQ
              @function.uses_float = true
            else
              @function.uses_i64 = true
            end
            sources = types.drop(1).reverse.map { |type| pop_typed(type) }.reverse
            dst = register(types.fetch(0))
            emit([opcode, dst] + sources) if @reachable
            @stack << dst
          end
        end
        fail_translation("missing function end") unless @controls.empty?
        @function
      end

      private

      # Validate even dead instructions before deciding whether to emit MIR.
      # @rbs code: Symbol
      # @rbs operands: Array[Wardite::operandItem]
      # @rbs return: void
      def validate_store_instruction(code, operands)
        @function.uses_store = true
        if code == :global_get || code == :global_set
          index = integer_operand(operands[0])
          global = index >= 0 ? @instance.store.globals[index] : nil
          fail_translation("invalid global index #{index}") unless global
          case global.type
          when :i32
            fail_translation("global initializer type mismatch") unless global.value.is_a?(Wardite::I32)
          when :i64
            fail_translation("global initializer type mismatch") unless global.value.is_a?(Wardite::I64)
          when :f32
            fail_translation("global initializer type mismatch") unless global.value.is_a?(Wardite::F32)
          when :f64
            fail_translation("global initializer type mismatch") unless global.value.is_a?(Wardite::F64)
          else
            raise UnsupportedFeature, context("only numeric global access is supported")
          end
          fail_translation("global.set on immutable global #{index}") if code == :global_set && !global.mutable
          return
        end
        fail_translation("memory instruction requires memory 0") if @instance.store.memories.empty?
        alignment = MEMORY_WIDTHS[code]
        if alignment
          hint = integer_operand(operands[0])
          offset = integer_operand(operands[1])
          fail_translation("invalid memory alignment") unless hint >= 0 && hint <= alignment
          fail_translation("invalid memory offset") unless offset >= 0 && offset <= 0xffffffff
        elsif code == :memory_init
          data_index = integer_operand(operands[0])
          fail_translation("memory.init requires data count") unless @instance.data_count_section
          count = @instance.data_section&.segments&.size || 0
          fail_translation("invalid data index #{data_index}") unless data_index >= 0 && data_index < count
          check_memory_index(integer_operand(operands[1]))
        elsif code == :memory_copy
          check_memory_index(integer_operand(operands[0]))
          check_memory_index(integer_operand(operands[1]))
        else
          check_memory_index(integer_operand(operands[0]))
        end
      end

      # @rbs index: Integer
      # @rbs return: void
      def check_memory_index(index)
        raise UnsupportedFeature, context("only memory 0 is supported") unless index == 0
      end

      # @rbs value: Wardite::operandItem?
      # @rbs return: Integer
      def integer_operand(value)
        fail_translation("expected integer operand") unless value.is_a?(Integer)
        value
      end

      # @rbs type: Symbol
      # @rbs return: Integer
      def register(type = :i32)
        @function.allocate_register(0, type: type)
      end

      # @rbs value: Integer
      # @rbs return: Integer
      # @rbs type: Symbol
      def constant(value, type = :i32)
        constants = case type
                    when :i64 then @i64_constants ||= {} #: Hash[Integer, Integer]
                    when :f32 then @f32_constants ||= {} #: Hash[Integer, Integer]
                    when :f64 then @f64_constants ||= {} #: Hash[Integer, Integer]
                    else @constants
                    end
        constants[value] ||= @function.allocate_constant(value, type: type)
      end

      # @rbs kind: Symbol
      # @rbs types: Array[Symbol]
      # @rbs return: Wardite::Efflorescence::Translator::Control
      def new_control(kind, types)
        Control.new(kind, @stack, @function.instructions.size, types, types.map { |type| register(type) }, @handler_depth, @reachable)
      end

      # @rbs instruction: Array[Integer]
      # @rbs return: Integer
      def emit(instruction)
        position = @function.instructions.size
        @function.instructions << Instruction.new(instruction)
        position
      end

      # @rbs pc: Integer
      # @rbs target: Integer
      # @rbs return: void
      def patch(pc, target)
        instruction = @function.instructions.fetch(pc)
        instruction[instruction.size - 1] = target
      end

      # @rbs return: Integer
      def pop_value
        control = @controls.last || raise(TranslationError, "missing control")
        if @stack.size == control.entry_stack.size
          return -1 if control.polymorphic
          fail_translation("operand stack underflow")
        end
        @stack.pop || raise(TranslationError, "missing operand")
      end

      # @rbs register: Integer
      # @rbs return: Symbol
      def type_of(register)
        register < 0 ? :unknown : @function.register_types.fetch(register)
      end

      # @rbs type: Symbol
      # @rbs return: Integer
      def pop_typed(type)
        value = pop_value
        fail_translation("expected #{type}, got #{type_of(value)}") unless value < 0 || type_of(value) == type
        value
      end

      # @rbs destination: Integer
      # @rbs source: Integer
      # @rbs return: void
      def copy_value(destination, source)
        fail_translation("copy type mismatch") unless type_of(destination) == type_of(source)
        emit([type_of(source) == :exnref ? Opcode::COPY_REF : Opcode::COPY, destination, source])
      end

      # @rbs destinations: Array[Integer]
      # @rbs sources: Array[Integer]
      # @rbs return: void
      def parallel_copy(destinations, sources)
        if sources.size > 1
          sources = sources.map do |source|
            temp = register(type_of(source))
            copy_value(temp, source)
            temp
          end
        end
        destinations.each_with_index { |dst, i| copy_value(dst, sources.fetch(i)) }
      end

      # @rbs local: Integer
      # @rbs return: void
      def preserve_local(local)
        return unless @stack.include?(local)
        snapshot = register(type_of(local))
        copy_value(snapshot, local)
        @stack.map! { |source| source == local ? snapshot : source }
      end

      # @rbs return: void
      def snapshot_locals
        @stack.dup.each { |source| preserve_local(source) if source < @function.parameter_count + @function.local_count }
      end

      # @rbs depth: Integer
      # @rbs return: Wardite::Efflorescence::Translator::Control
      def label(depth)
        fail_translation("invalid branch depth #{depth}") unless depth >= 0 && depth < @controls.size
        @controls.fetch(@controls.size - 1 - depth)
      end

      # @rbs target: Wardite::Efflorescence::Translator::Control
      # @rbs return: Array[Symbol]
      def label_types(target)
        target.kind == :loop ? [] : target.result_types
      end

      # @rbs types: Array[Symbol]
      # @rbs return: Array[Integer]
      def top_values(types)
        return [] if types.empty?

        control = @controls.last || raise(TranslationError, "missing control")
        available = @stack.size - control.entry_stack.size
        if available < types.size
          fail_translation("operand stack underflow") unless control.polymorphic
          values = Array.new(types.size - available, -1) + @stack.last(available)
        else
          values = @stack.last(types.size)
        end
        values.each_with_index do |value, i|
          fail_translation("branch result type mismatch") if value >= 0 && type_of(value) != types.fetch(i)
        end
        values
      end

      # @rbs target: Wardite::Efflorescence::Translator::Control
      # @rbs sources: Array[Integer]
      # @rbs condition: Integer
      # @rbs return: void
      def branch(target, sources, condition = -1)
        parallel_copy(target.result_registers, sources) unless target.kind == :loop
        emit([Opcode::EH_TRIM, target.handler_depth]) if @handler_depth != target.handler_depth
        pc = target.kind == :loop ? target.start_pc : -1
        position = emit(condition < 0 ? [Opcode::BR, pc] : [Opcode::BR_IF, condition, pc])
        unless target.kind == :loop
          target.patches << position
          target.has_branch = true
        end
      end

      # @rbs index: Integer
      # @rbs return: Wardite::Efflorescence::Tag
      def tag_at(index)
        fail_translation("invalid tag index #{index}") if index < 0
        @instance.tags[index] || raise(TranslationError, context("invalid tag index #{index}"))
      end

      # Catch labels resolve before pushing the try_table's own label.
      # @rbs clauses: Array[Integer]
      # @rbs return: Wardite::Efflorescence::HandlerDescriptor
      def make_handler(clauses)
        targets = [] #: Array[Wardite::Efflorescence::CatchTarget]
        clauses.each_slice(3) do |clause|
          kind, tag_index, depth = clause.fetch(0), clause.fetch(1), clause.fetch(2)
          target = label(depth)
          types = kind <= 1 ? tag_at(tag_index).parameter_types.dup : [] #: Array[Symbol]
          reference = kind == 1 || kind == 3
          types << :exnref if reference
          fail_translation("catch payload/label type mismatch") unless types == label_types(target)
          destinations = target.kind == :loop ? [] : target.result_registers.dup #: Array[Integer]
          ref = reference ? (destinations.pop || raise(TranslationError, "missing reference result")) : -1
          entry = CatchTarget.new(tag_index, destinations, ref, target.kind == :loop ? target.start_pc : -1, target.handler_depth)
          if target.kind != :loop
            target.catch_patches << entry
            target.has_branch = true if @reachable
          end
          targets << entry
        end
        HandlerDescriptor.new(targets)
      end

      # @rbs control: Wardite::Efflorescence::Translator::Control
      # @rbs return: void
      def finish_arm(control)
        height = @stack.size - control.entry_stack.size
        fail_translation("incorrect stack height at end") if height > control.result_types.size
        sources = top_values(control.result_types)
        parallel_copy(control.result_registers, sources) if @reachable && !sources.empty?
      end

      # @rbs return: void
      def else_control
        control = @controls.last || raise(TranslationError, "unexpected else")
        fail_translation("unexpected else") unless control.kind == :if && !control.else_seen
        finish_arm(control)
        control.then_reachable = @reachable
        control.patches << emit([Opcode::BR, -1]) if @reachable
        patch(control.false_patch, @function.instructions.size) if control.false_patch >= 0
        control.else_seen = true
        control.polymorphic = false
        @stack = control.entry_stack.dup
        @reachable = control.entry_reachable
      end

      # @rbs return: void
      def end_control
        control = @controls.last || raise(TranslationError, "unexpected end")
        finish_arm(control)
        if control.kind == :try_table
          @handler_depth = control.handler_depth
          emit([Opcode::EH_TRIM, @handler_depth]) if @reachable
        end
        if control.kind == :if && !control.else_seen
          fail_translation("result-bearing if requires else") unless control.result_types.empty?
          patch(control.false_patch, @function.instructions.size) if control.false_patch >= 0
          @reachable ||= control.entry_reachable
        end
        @controls.pop
        pc = @function.instructions.size
        control.patches.each { |position| patch(position, pc) }
        control.catch_patches.each { |entry| entry.target_pc = pc }
        @stack = control.entry_stack.dup + control.result_registers
        @reachable = @reachable || control.has_branch || control.then_reachable
        if control.kind == :function
          emit([Opcode::RETURN, control.result_registers.empty? ? -1 : control.result_registers.fetch(0)])
        end
      end

      # @rbs return: void
      def mark_unreachable
        control = @controls.last || raise(TranslationError, "missing control")
        control.polymorphic = true
        @stack = control.entry_stack.dup
        @reachable = false
      end

      # @rbs message: String
      # @rbs return: String
      def context(message)
        "Efflorescence: function #{@function.index}, Wasm PC #{@wasm_pc}: #{message}"
      end

      # @rbs message: String
      # @rbs return: bot
      def fail_translation(message)
        raise TranslationError, context(message)
      end
    end
  end
end
