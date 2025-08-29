# rbs_inline: enabled
module Wardite
  class Revisitor
    attr_accessor :ops #: Array[Op]
    
    # @rbs ops: Array[Op]
    # @rbs return: void
    def initialize(ops)
      @ops = ops
    end

    # @rbs return: void
    def revisit!
      @ops.each_with_index do |op, idx|
        case op.code
        when :block
          next_pc = fetch_ops_while_end(idx)
          if op.meta[:end_pos] != next_pc
            raise "mismatched end_pos for block at #{op}: #{op.meta[:end_pos]} vs #{next_pc}"
          end
  
        when :loop
          next_pc = fetch_ops_while_end(idx)
          if op.meta[:end_pos] != next_pc
            raise "mismatched end_pos for loop at #{op}: #{op.meta[:end_pos]} vs #{next_pc}"
          end
  
        when :if
          next_pc = fetch_ops_while_end(idx)
          else_pc = fetch_ops_while_else_or_end(idx)
          if op.meta[:end_pos] != next_pc
            raise "mismatched end_pos for if at #{op}: #{op.meta[:end_pos]} vs #{next_pc}"
          end
          if op.meta[:else_pos] != else_pc
            raise "mismatched else_pos for if at #{op}: #{op.meta[:else_pos]} vs #{else_pc}"
          end
        end
      end
    end

    # @rbs pc_start: Integer
    # @rbs return: Integer
    # @rbs return: void
    def fetch_ops_while_else_or_end(pc_start)
      cursor = pc_start
      depth = 0
      loop {
        cursor += 1
        inst = @ops[cursor]
        case inst&.code
        when nil
          raise EvalError, "end op not found"
        when :if, :block, :loop
          depth += 1
        when :else
          if depth == 0
            return cursor
          end
          # do not touch depth
        when :end
          if depth == 0
            return cursor
          else
            depth -= 1
          end
        else
          # nop
        end
      }
      raise "not found corresponding end"
    end

    # @rbs pc_start: Integer
    # @rbs return: Integer
    # @rbs return: void
    def fetch_ops_while_end(pc_start)
      cursor = pc_start
      depth = 0
      loop {
        cursor += 1
        inst = @ops[cursor]
        case inst&.code
        when nil
          raise EvalError, "end op not found"
        when :if, :block, :loop
          depth += 1
        when :end
          if depth == 0
            return cursor
          else
            depth -= 1
          end
        else
          # nop
        end
      }
      raise "not found corresponding end"
    end
  end
end