# frozen_string_literal: true

# CRuby. Compare the boxed and unboxed WASI paths in the same Efflorescence VM.
require "wardite"
require "wardite/wasi"
require "open3"
require "tmpdir"

wat = <<~WAT
  (module
    (import "wasi_snapshot_preview1" "fd_write" (func $write (param i32 i32 i32 i32) (result i32)))
    (memory 1)
    (data (i32.const 0) "\\20\\00\\00\\00\\04\\00\\00\\00")
    (data (i32.const 32) "data")
    (func (export "run") (param $rounds i32) (result i32) (local $bytes i32)
      block $done
        loop $repeat
          local.get $rounds i32.eqz br_if $done
          i32.const 1 i32.const 0 i32.const 1 i32.const 8 call $write
          if unreachable end
          local.get $bytes i32.const 8 i32.load i32.add local.set $bytes
          local.get $rounds i32.const 1 i32.sub local.set $rounds
          br $repeat
        end
      end
      local.get $bytes))
WAT

rounds = Integer(ENV.fetch("ROUNDS", "100000"))
runs = Integer(ENV.fetch("RUNS", "5"))
abort "invalid rounds or runs" unless rounds.between?(1, 0x3fffffff) && runs.positive?
Dir.mktmpdir("wardite-wasi-bench") do |dir|
  wat_path = File.join(dir, "write.wat")
  wasm_path = File.join(dir, "write.wasm")
  File.write(wat_path, wat)
  output, status = Open3.capture2e("wasm-tools", "parse", wat_path, "-o", wasm_path)
  abort output unless status.success?

  measurements = {"boxed" => [], "unboxed" => []}
  File.open(IO::NULL, "wb") do |sink|
    sink.sync = true
    (runs + 2).times do |index|
      measurements.keys.rotate(index).each do |mode|
        if mode == "boxed"
          wasi = Wardite::WasiSnapshotPreview1.new
          instance = Wardite.new(path: wasm_path, engine: :efflorescence, enable_wasi: false,
            import_object: {wasi_snapshot_preview1: wasi})
        else
          instance = Wardite.new(path: wasm_path, engine: :efflorescence)
          wasi = instance.wasi
        end
        wasi.fd_table[1] = sink
        vm = instance.runtime
        native = vm.ir.hosts.fetch(0).unboxed_wasi
        abort "unexpected ABI for #{mode}" unless !!native == (mode == "unboxed")

        objects = GC.stat(:total_allocated_objects)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        checksum = vm.call_unboxed(:run, [rounds])
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        allocations = GC.stat(:total_allocated_objects) - objects
        abort "expected #{rounds * 4} bytes, got #{checksum}" unless checksum == rounds * 4
        measurements.fetch(mode) << [elapsed * 1000, allocations] if index >= 2
      end
    end
  end
  puts "abi,rounds,bytes,median_ms,min_ms,max_ms,median_allocations"
  measurements.each do |mode, observations|
    times, objects = observations.transpose.map(&:sort)
    low, high = (runs - 1) / 2, runs / 2
    median_ms = (times[low] + times[high]) / 2
    median_objects = (objects[low] + objects[high]) / 2
    puts "%s,%d,%d,%.3f,%.3f,%.3f,%d" % [mode, rounds, rounds * 4, median_ms, times.first, times.last, median_objects]
  end
end
