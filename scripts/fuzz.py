#!/usr/bin/env python3
"""
Usage:
  ./scripts/fuzz.py --binary ./zig-out/bin/jaslc-debug --iterations 20000
"""
import argparse
import os
import random
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEED_DIRS = [ROOT / "tests/corpus", ROOT / "tests/fixtures/valid", ROOT / "demo"]
CRASH_DIR = ROOT / "tests/crashes"

TOKENS = [
    b"let", b"fn", b"struct", b"enum", b"union", b"if", b"else", b"while",
    b"for", b"switch", b"return", b"break", b"continue", b"import", b"mut",
    b"pub", b"true", b"false", b"i32", b"f32", b"->", b"::", b"{", b"}",
    b"(", b")", b"[", b"]", b";", b",", b".", b":", b"=", b"==", b"!=",
    b"+", b"-", b"*", b"/", b"\"", b"\"unterminated", b"0", b"1234567890",
    b"9999999999999999999999", b"3.14", b"_", b"..", b"\x00", b"\xff",
]


def load_seeds():
    seeds = []
    for d in SEED_DIRS:
        if d.exists():
            seeds += [p.read_bytes() for p in d.rglob("*.jasl")]
    if not seeds:
        seeds = [b"let main = fn () -> i32 { return 0; };"]
    return seeds


def mutate(data: bytes) -> bytes:
    data = bytearray(data)
    op = random.random()
    if op < 0.3 and data:
        # bit/byte flip
        for _ in range(random.randint(1, 8)):
            i = random.randrange(len(data))
            data[i] = random.randrange(256)
    elif op < 0.55:
        # delete a chunk
        if len(data) > 4:
            i = random.randrange(len(data))
            j = min(len(data), i + random.randint(1, 20))
            del data[i:j]
    elif op < 0.8:
        # insert a random known token at a random position
        i = random.randrange(len(data) + 1)
        tok = random.choice(TOKENS)
        data[i:i] = tok
    else:
        # duplicate a chunk (stresses nesting/recursion depth)
        if len(data) > 4:
            i = random.randrange(len(data))
            j = min(len(data), i + random.randint(1, 40))
            data[i:i] = data[i:j]
    return bytes(data)


def run_one(binary, path, timeout):
    try:
        proc = subprocess.run(
            [binary, str(path), "--parse-only"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return "timeout", None
    # Negative returncode on POSIX == killed by signal (segfault, abort, etc).
    if proc.returncode < 0:
        return "signal", proc.returncode
    # jaslc's documented error paths return small positive codes; anything
    # wildly large/unexpected plus a Zig panic trace is worth a look.
    if b"panic" in proc.stderr.lower() or b"reached unreachable" in proc.stderr.lower():
        return "panic", proc.returncode
    return "ok", proc.returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default="./zig-out/bin/jaslc-debug")
    ap.add_argument("--iterations", type=int, default=5000)
    ap.add_argument("--timeout", type=float, default=2.0)
    ap.add_argument("--seed", type=int, default=None)
    args = ap.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    if not os.path.isfile(args.binary) or not os.access(args.binary, os.X_OK):
        print(f"Binary not found/executable: {args.binary}", file=sys.stderr)
        print("Build first: zig build debug", file=sys.stderr)
        sys.exit(2)

    CRASH_DIR.mkdir(parents=True, exist_ok=True)
    seeds = load_seeds()
    scratch = ROOT / "tests/.fuzz_scratch.jasl"

    findings = 0
    t0 = time.time()
    for i in range(args.iterations):
        base = random.choice(seeds)
        candidate = mutate(base)
        scratch.write_bytes(candidate)

        status, code = run_one(args.binary, scratch, args.timeout)
        if status != "ok":
            findings += 1
            out = CRASH_DIR / f"{status}_{i}_{code}.jasl"
            out.write_bytes(candidate)
            print(f"[{status}] exit={code} -> saved {out}")

        if i % 500 == 0 and i:
            print(f"{i}/{args.iterations} run, {findings} findings, "
                  f"{i/(time.time()-t0):.0f} exec/s")

    print(f"Done. {findings} findings in {args.iterations} runs. "
          f"See {CRASH_DIR} for reproducers.")
    sys.exit(1 if findings else 0)


if __name__ == "__main__":
    main()
