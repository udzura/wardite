# frozen_string_literal: true

module LegacyWasmDecode
  def self.operand_of(code)
    case code
    when :local_get, :local_set, :local_tee, :global_get, :global_set, :call, :br, :br_if, :throw, :data_drop
      [:u32]
    when :memory_init, :memory_copy
      [:u32, :u32]
    when :memory_size, :memory_grow, :memory_fill
      [:u32]
    when :call_indirect
      [:u32, :u32]
    when :br_table
      [:u32_vec, :u32]
    when :i32_const
      [:i32]
    when :i64_const
      [:i64]
    when :f32_const
      [:f32]
    when :f64_const
      [:f64]
    when :if, :block, :loop
      [:blocktype]
    when :try_table
      [:blocktype, :catches]
    when :i32_load, :i64_load, :f32_load, :f64_load, :i32_load8_s, :i32_load8_u, :i32_load16_s, :i32_load16_u,
         :i64_load8_s, :i64_load8_u, :i64_load16_s, :i64_load16_u, :i64_load32_s, :i64_load32_u, :i32_store, :i64_store,
         :f32_store, :f64_store, :i32_store8, :i32_store16, :i64_store8, :i64_store16, :i64_store32
      [:u32, :u32]
    else
      []
    end
  end
end
