#!/usr/bin/env python3
"""Check moonzip's streams against Python's zlib, which is zlib itself.

    moon run examples/vectors | python3 scripts/conformance.py

Every line the example prints carries a stream we wrote. This hands each one to
Python and asks for the input back, so "others can read what we write" stays
true instead of being asserted once and left to rot. The other direction -- we
read what zlib writes -- is the fixed vectors in the test suites; this script is
the half that cannot be pinned, because our encoder is allowed to improve and
its bytes are allowed to change.
"""

import io
import sys
import lzma
import zipfile
import zlib


def sample(kind):
    """The same seven inputs examples/vectors builds, byte for byte."""
    if kind == 0:
        return b""
    if kind == 1:
        return b"a"
    if kind == 2:
        return b"a" * 1000
    if kind == 3:
        out = bytearray()
        for i in range(500):
            out += b"the quick brown fox jumps over the lazy dog. "
            out.append(i % 251)
        return bytes(out)
    if kind == 4:
        return bytes((i * 71 % 251) for i in range(3000))
    if kind == 5:
        return bytes((i % 4) for i in range(2000))
    return bytes((i % 13) for i in range(70000))


def main():
    checked = 0
    failed = 0
    for line in sys.stdin:
        parts = line.split()
        if not parts:
            continue
        form = parts[0]
        if form == "zip":
            kind, variant = int(parts[1]), int(parts[2])
            blob = bytes.fromhex(parts[3])
            password = b"moonzip" if variant == 3 else None
            try:
                with zipfile.ZipFile(io.BytesIO(blob)) as archive:
                    names = archive.namelist()
                    if names != ["first.txt", "dir/second.txt"]:
                        raise ValueError("names are {}".format(names))
                    first = archive.read("first.txt", pwd=password)
                    second = archive.read("dir/second.txt", pwd=password)
                    if second != b"the second member":
                        raise ValueError("the second member is wrong")
                if first != sample(kind):
                    raise ValueError("the first member is wrong")
                checked += 1
                continue
            except Exception as why:  # noqa: BLE001 - report, do not raise
                failed += 1
                print("FAIL zip {} variant={}: {}".format(kind, variant, why))
                continue
        if form == "stream":
            # Written a piece at a time, so the block boundaries are not the
            # ones a single call would produce — still one stream, still has to
            # read back.
            inner, kind = parts[1], int(parts[2])
            step, blob = parts[3], bytes.fromhex(parts[4])
            want = sample(kind)
            got = zlib.decompressobj(31 if inner == "gzip" else 15).decompress(blob)
            what = "stream {} {} step={}".format(inner, kind, step)
        else:
            kind, rest = int(parts[1]), parts[2:]
            want = sample(kind)
            if form == "deflate":
                level, blocks, blob = rest[0], rest[1], bytes.fromhex(rest[2])
                got = zlib.decompressobj(-15).decompress(blob)
                what = "deflate {} level={} blocks={}".format(kind, level, blocks)
            elif form == "gzip":
                blob = bytes.fromhex(rest[0])
                got = zlib.decompressobj(31).decompress(blob)
                what = "gzip {}".format(kind)
            elif form == "lzma":
                blob = bytes.fromhex(rest[0])
                got = lzma.decompress(blob, format=lzma.FORMAT_ALONE)
                what = "lzma {}".format(kind)
            elif form == "zlib":
                blob = bytes.fromhex(rest[0])
                got = zlib.decompressobj(15).decompress(blob)
                what = "zlib {}".format(kind)
            else:
                continue
        checked += 1
        if got != want:
            failed += 1
            print("FAIL {}: {} bytes, want {}".format(what, len(got), len(want)))
            for i in range(min(len(got), len(want))):
                if got[i] != want[i]:
                    print("  first difference at byte {}".format(i))
                    break
    print("{} streams checked, {} failed".format(checked, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
