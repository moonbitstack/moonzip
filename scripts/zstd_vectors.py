#!/usr/bin/env python3
"""Regenerate `zstd/interop_test.mbt` from frames Node's libzstd wrote.

    python3 scripts/zstd_vectors.py

Node 22 ships zstd in its `zlib` module, which is the reference implementation
compiled in. That makes it the judge for this format: these frames were written
by libzstd and must read back byte for byte, and `scripts/conformance.py` hands
our frames to the same library in the other direction.
"""

import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent

SCRIPT = r"""
const zlib = require('zlib');
const cases = [];
function add(name, body, generator) {
  cases.push({ name, generator, body: Buffer.from(body).toString('hex'),
               frame: zlib.zstdCompressSync(Buffer.from(body)).toString('hex') });
}
add('text', 'the quick brown fox jumps over the lazy dog. '.repeat(20));
add('single', 'a');
add('run', 'z'.repeat(5000));
const noise = []; let x = 12345;
for (let i = 0; i < 4096; i++) { x = (Math.imul(x, 1103515245) + 12345) >>> 0; noise.push((x >> 16) & 0xff); }
add('noise', noise);
const all = []; for (let i = 0; i < 256; i++) all.push(i);
add('alphabet', all.concat(all));
add('repeat', Array.from({length: 200000}, (_, i) => 0x41 + (i % 17)), 'repeat');
process.stdout.write(JSON.stringify(cases));
"""

GENERATORS = {
    "repeat": """    let body : Array[Byte] = []
    for i in 0..<200000 {
      body.push((65 + (i % 17)).to_byte())
    }""",
}

HEAD = """// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Frames written by libzstd — the implementation inside Node's `zlib` — pinned
/// as they came out.
///
/// Every one of them has to decode to exactly the bytes that were compressed,
/// which is the only thing that says a decoder is a decoder rather than a
/// program that agrees with itself.
///
///     python3 scripts/zstd_vectors.py
///
/// regenerates this file. It needs `node` on the path.
"""


def chunks(text, width=64):
    return [text[i:i + width] for i in range(0, len(text), width)]


def main():
    out = subprocess.run(["node", "-e", SCRIPT], capture_output=True, text=True, check=True)
    cases = json.loads(out.stdout)
    lines = [HEAD]
    for case in cases:
        name = case["name"]
        lines.append("///|\n/// %s.\n" % name)
        lines.append("fn frame_%s() -> Bytes {\n  @base16.decode_lossy(\n" % name)
        lines.append(" +\n".join('    "%s"' % c for c in chunks(case["frame"])))
        lines.append(",\n  )\n}\n")
        lines.append("///|\nfn body_%s() -> Bytes {\n" % name)
        if name in GENERATORS:
            lines.append(GENERATORS[name] + "\n  Bytes::from_array(body)\n}\n")
        else:
            lines.append("  @base16.decode_lossy(\n")
            lines.append(" +\n".join('    "%s"' % c for c in chunks(case["body"])))
            lines.append(",\n  )\n}\n")
    lines.append("///|\n/// Every frame reads back.\ntest \"frames written by libzstd read back\" {\n")
    for case in cases:
        name = case["name"]
        lines.append("  assert_eq(@zstd.unzstd(frame_%s()[:]), body_%s())\n" % (name, name))
    lines.append("}\n")
    path = ROOT / "src" / "zstd" / "interop_test.mbt"
    path.write_text("".join(lines), encoding="utf-8", newline="\n")
    total = sum(len(c["frame"]) // 2 for c in cases)
    print("wrote %s (%d frames, %d bytes)" % (path, len(cases), total))


if __name__ == "__main__":
    main()
