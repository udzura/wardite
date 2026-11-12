# frozen_string_literal: true

require "open3"
require_relative "efflorescence_helper"

# A WASI command whose first fd_write runs in a nested frame, under an
# exception handler, after memory.grow, random_get, and i32/i64 global writes.
module SnapshotFixture
  include EfflorescenceHelper

  WRITE_CALLS = {
    direct: "(call $write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 16))",
    indirect: "(call_indirect (type $writer) (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 16) (i32.const 0))",
  }.freeze

  # @rbs variant: Symbol
  # @rbs return: String
  def snapshot_wat(variant)
    <<~WAT
      (module
        (type $writer (func (param i32 i32 i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "random_get" (func $random (param i32 i32) (result i32)))
        (import "wasi_snapshot_preview1" "fd_write" (func $write (type $writer)))
        (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
        (memory (export "memory") 1)
        (global $counter (mut i32) (i32.const 0))
        (global $wide (mut i64) (i64.const 0))
        (table 1 funcref)
        (elem (i32.const 0) $write)
        (tag $done (param i32))
        (func $line (param $mark i32) (result i32)
          (i32.store8 (i32.const 32) (i32.add (i32.const 97) (i32.rem_u (global.get $counter) (i32.const 26))))
          (i32.store8 (i32.const 33) (i32.add (i32.const 97) (i32.rem_u (i32.load8_u (i32.const 100)) (i32.const 26))))
          (i32.store8 (i32.const 34) (i32.load8_u (i32.const 65544)))
          (i32.store8 (i32.const 35) (select (i32.const 45) (i32.const 43) (i64.lt_s (global.get $wide) (i64.const 0))))
          (i32.store8 (i32.const 36) (i32.add (i32.const 48) (local.get $mark)))
          (i32.store8 (i32.const 37) (i32.const 10))
          (i32.store (i32.const 0) (i32.const 32))
          (i32.store (i32.const 4) (i32.const 6))
          #{WRITE_CALLS.fetch(variant)})
        (func (export "_start") (local $i i32)
          (drop (call $random (i32.const 100) (i32.const 4)))
          (drop (memory.grow (i32.const 1)))
          (i32.store8 (i32.const 65544) (i32.const 90))
          (block $out
            (loop $again
              (br_if $out (i32.gt_u (local.get $i) (i32.const 100)))
              (global.set $counter (i32.add (global.get $counter) (local.get $i)))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $again)))
          (global.set $wide (i64.const -5050))
          (call $exit
            (block $caught (result i32)
              (try_table (catch $done $caught)
                (drop (call $line (i32.const 1)))
                (drop (call $line (i32.const 2)))
                (throw $done (i32.const 3)))
              (unreachable)))))
    WAT
  end

  # @rbs directory: String
  # @rbs variant: Symbol
  # @rbs return: String
  def write_snapshot_fixture(directory, variant)
    path = File.join(directory, "#{variant}.wasm")
    File.binwrite(path, compile_efflorescence_wat(snapshot_wat(variant)))
    path
  end

  # @rbs command: Array[String]
  # @rbs directory: String
  # @rbs wasm: String
  # @rbs *guest_args: String
  # @rbs return: [String, String, Process::Status]
  def run_snapshot(command, directory, wasm, *guest_args)
    args = [*command, "--new-engine", "--mir-cache", File.join(directory, "cache"),
      "--snapshot", File.join(directory, "snapshot"), "--", wasm, *guest_args]
    Open3.capture3({"WARDITE_TRACE" => "1"}, *args)
  end
end
