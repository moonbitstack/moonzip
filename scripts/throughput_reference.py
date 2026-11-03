#!/usr/bin/env python3
"""Time a reference zlib against the body `src/examples/throughput` builds.

The corpus generator is transcribed here byte for byte from the MoonBit example so
that the two programs are fed the same input; the point of the example is a
comparison, and a comparison against a different body is not one.

    python3 scripts/throughput_reference.py

The median of ten timed runs after a warm-up, in megabytes per second, which is
what the example reports and what the README quotes.
"""

import statistics
import time
import zlib

WORDS = [
    "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota",
    "kappa", "lambda", "mu", "nu", "xi", "omicron", "pi",
]


def corpus():
    out = bytearray()
    state = 123456789
    while len(out) < 1500000:
        state = (state * 1103515245 + 12345) & 0xFFFFFFFF
        out += WORDS[((state >> 16) & 0xFFFF) % 16].encode()
        out += b" "
        out += str((state >> 8) % 1000).encode()
        out += b" "
    return bytes(out)


def median_micros(action):
    action()
    runs = []
    for _ in range(10):
        start = time.perf_counter()
        action()
        runs.append((time.perf_counter() - start) * 1e6)
    return statistics.median(runs)


def main():
    body = corpus()
    n = len(body)
    print(f"body: {n} bytes of words and numbers")
    packed = [zlib.compress(body, 6)]
    write = median_micros(lambda: packed.__setitem__(0, zlib.compress(body, 6)))
    blob = packed[0]
    read = median_micros(lambda: zlib.decompress(blob))
    print(f"zlib write: {n / write} MB/s")
    print(f"zlib read : {n / read} MB/s")
    print(f"packed: {len(blob)} bytes")


if __name__ == "__main__":
    main()
