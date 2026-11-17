#!/usr/bin/env python3

import argparse
import csv
import os
from pathlib import Path
import re
import subprocess
import sys
from tempfile import TemporaryDirectory
from time import perf_counter_ns


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, capture_output=True, **kwargs)


def measure(binaries, cache_root, writer, case, wasm, args, expected, *,
            rounds, stdin=None, cache=False, timed=False, invoke=None):
    trace_env = dict(os.environ, WARDITE_TRACE="1")
    commands = {}
    for index, (name, binary) in enumerate(binaries):
        cmd = [binary]
        if cache:
            cmd += ["--mir-cache", str(cache_root / str(index))]
        if invoke:
            cmd += ["--no-wasi", "--invoke", invoke]
        commands[name] = cmd + ["--", str(wasm), *map(str, args)]

    def sample(name, input_file):
        if input_file:
            input_file.seek(0)
        started = perf_counter_ns()
        result = subprocess.run(commands[name], stdin=input_file, stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, env=trace_env, check=True)
        elapsed = perf_counter_ns() - started
        trace = result.stderr.decode()
        if cache and "MIR2 cache hit:" not in trace:
            raise ValueError(f"{name} {case} missed MIR2 cache: {trace}")
        if invoke:
            match = re.search(r"return value: I(32|64)\((-?\d+)\)", trace)
            if not match:
                raise ValueError(f"missing return value: {trace}")
            width = int(match[1])
            mask = (1 << width) - 1
            if (int(match[2]) & mask) != (expected & mask):
                raise ValueError(f"{name} {case} returned {match[2]}, expected {expected}")
        load_ms = float(re.search(r"load_from_buffer: ([0-9.eE+-]+)", trace)[1]) * 1000
        transform_ms = ""
        if timed:
            transform_ms = int(re.search(r"base64_transform_ns: (\d+)", trace)[1]) / 1e6
        return elapsed / 1e6, load_ms, elapsed / 1e6 - load_ms, transform_ms

    names = [name for name, _ in binaries]
    for name in names:
        result = run(commands[name], input=stdin.read_bytes() if stdin else None, env=trace_env)
        if not invoke and result.stdout != expected:
            raise ValueError(f"{name} {case} output differs from the reference")

    with (stdin or Path(os.devnull)).open("rb") as input_file:
        for index in range(-2, rounds):
            # Alternate the run order within each case after warming each binary twice.
            for name in (names if index % 2 == 0 else reversed(names)):
                values = sample(name, input_file)
                if index >= 0:
                    timings = [f"{value:.6f}" if value != "" else "" for value in values]
                    writer.writerow((case, name, index + 1, *timings))


def main():
    parser = argparse.ArgumentParser(description="Compare Spinel Wardite memory load timings")
    parser.add_argument("benches", type=Path, help="wardite-benches checkout with built examples and fixtures")
    parser.add_argument("timed_base64", type=Path, help="base64_codec.wasm instrumented with base64_transform_ns")
    parser.add_argument("binaries", nargs="+", metavar="NAME=BINARY")
    parser.add_argument("--rounds", type=int, default=11)
    args = parser.parse_args()

    binaries = [entry.split("=", 1) for entry in args.binaries]
    if any(len(entry) != 2 or not all(entry) for entry in binaries):
        parser.error("each binary must be specified as NAME=BINARY")
    if len({name for name, _ in binaries}) != len(binaries):
        parser.error("binary names must be distinct")
    bench = Path(__file__).resolve().parent
    fixtures = args.benches / "build" / "fixtures"
    codec = args.benches / "build/rust/wasm32-wasip1/release/examples/base64_codec.wasm"
    data = fixtures / "data.bin"
    encoded = fixtures / "data.b64"
    writer = csv.writer(sys.stdout, lineterminator="\n")
    writer.writerow(("case", "build", "run", "process_ms", "load_ms", "process_minus_load_ms", "transform_ms"))

    with TemporaryDirectory(prefix="wardite-linear-loads-") as directory:
        root = Path(directory)
        for wasm, timed in ((codec, False), (args.timed_base64, True)):
            for mode, stdin, output in (("encode", data, encoded), ("decode", encoded, data)):
                expected = output.read_bytes()
                reference = run(["wasmtime", "run", wasm, mode], input=stdin.read_bytes())
                if reference.stdout != expected:
                    raise ValueError(f"Wasmtime {mode} output differs from the reference")
                for cache in (False, True):
                    case = f"{mode}_{'hit' if cache else 'off'}{'_timed' if timed else ''}"
                    measure(binaries, root, writer, case, wasm, [mode], expected,
                            rounds=args.rounds, stdin=stdin, cache=cache, timed=timed)

        for source, exports in (
            ("linear_memory_loads", ("lookup8", "unaligned64", "mixed_width")),
            ("i32_memory", ("array_scan", "array_scan_grown")),
        ):
            wasm = root / f"{source}.wasm"
            run(["wat2wasm", bench / f"{source}.wat", "-o", wasm])
            for export in exports:
                arguments = ([(400_000, 0), (400_000, 1)] if source == "linear_memory_loads"
                             else [(1600, 17)])
                for params in arguments:
                    case = f"{export}_{'grown' if params[1] else 'owned'}" if len(arguments) > 1 else export
                    reference = run(["wasmtime", "run", "--invoke", export, wasm, *map(str, params)])
                    measure(binaries, root, writer, case, wasm, params, int(reference.stdout),
                            rounds=args.rounds, invoke=export)


if __name__ == "__main__":
    main()
