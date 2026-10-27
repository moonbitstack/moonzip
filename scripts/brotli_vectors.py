#!/usr/bin/env python3
"""Regenerate `brotli/interop_test.mbt` from streams libbrotli wrote.

    python3 scripts/brotli_vectors.py

Node 22 bundles libbrotli behind `zlib.brotliCompressSync`, which is the
reference implementation compiled in. That makes it the judge for this format in
both directions: these streams were written by libbrotli and must read back byte
for byte, and `scripts/brotli_check.js` hands our streams to the same library.

The interesting cases are not the big ones. They are quality 11 on ordinary
English — which is where the encoder starts naming words in the 122 KB static
dictionary instead of spelling them — and the smallest window, which is where a
back-reference that reaches too far shows up as a wrong byte instead of an error.
"""

import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Each case is compressed at every quality in QUALITIES; the window ones get one
# extra frame at the small and the largest window.
SCRIPT = r"""
const zlib = require('zlib');
const C = zlib.constants;
const qualities = [0, 1, 5, 9, 11];
const frames = [];
function add(name, body) {
  const buf = Buffer.from(body);
  for (const q of qualities) {
    const frame = zlib.brotliCompressSync(buf, {
      params: {
        [C.BROTLI_PARAM_QUALITY]: q,
        [C.BROTLI_PARAM_LGWIN]: 22,
        [C.BROTLI_PARAM_MODE]: C.BROTLI_MODE_GENERIC,
      },
    });
    frames.push({ name, tag: 'q' + q, quality: q, window: 22, body: buf.toString('hex'),
                  frame: frame.toString('hex') });
  }
  for (const w of [10, 16, 24]) {
    const frame = zlib.brotliCompressSync(buf, {
      params: {
        [C.BROTLI_PARAM_QUALITY]: 9,
        [C.BROTLI_PARAM_LGWIN]: w,
        [C.BROTLI_PARAM_MODE]: C.BROTLI_MODE_GENERIC,
      },
    });
    frames.push({ name, tag: 'w' + w, quality: 9, window: w, body: buf.toString('hex'),
                  frame: frame.toString('hex') });
  }
}
function addText(name, body) {
  const buf = Buffer.from(body);
  for (const mode of [C.BROTLI_MODE_TEXT, C.BROTLI_MODE_FONT]) {
    const frame = zlib.brotliCompressSync(buf, {
      params: {
        [C.BROTLI_PARAM_QUALITY]: 11,
        [C.BROTLI_PARAM_LGWIN]: 22,
        [C.BROTLI_PARAM_MODE]: mode,
      },
    });
    frames.push({ name, tag: mode === C.BROTLI_MODE_TEXT ? 'text' : 'font',
                  quality: 11, window: 22, body: buf.toString('hex'),
                  frame: frame.toString('hex') });
  }
}

add('empty', '');
add('single', 'a');
add('run', 'z'.repeat(5000));
add('text', ('the quick brown fox jumps over the lazy dog. ' +
  'Brotli was designed for the web, and the dictionary it carries is the reason ' +
  'a small page costs less than its letters. ') .repeat(12));
add('html', ('<!doctype html><html><head><title>moonzip</title></head><body>' +
  '<div class="row"><span class="label">size</span><span class="value">42</span></div>' +
  '</body></html>').repeat(20));
add('json', JSON.stringify(Array.from({length: 120}, (_, i) => ({
  name: 'entry-' + i, size: i * 37, tags: ['a', 'b', 'c'].slice(0, 1 + (i % 3)),
  nested: { ok: i % 2 === 0, ratio: (i / 7).toFixed(3) },
}))));
const noise = []; let x = 12345;
for (let i = 0; i < 4096; i++) { x = (Math.imul(x, 1103515245) + 12345) >>> 0; noise.push((x >> 16) & 0xff); }
add('noise', noise);
const all = []; for (let i = 0; i < 256; i++) all.push(i);
add('alphabet', all.concat(all.map(v => 255 - v)));
const long = []; for (let i = 0; i < 70000; i++) long.push(65 + (i % 17));
add('long', long);
addText('prose', ('It was the best of times, it was the worst of times, it was the age of ' +
  'wisdom, it was the age of foolishness, it was the epoch of belief, it was the ' +
  'epoch of incredulity, it was the season of Light, it was the season of Darkness. ').repeat(6));
process.stdout.write(JSON.stringify(frames));
"""

GENERATORS = {
    "long": """    let body : Array[Byte] = []
    for i in 0..<70000 {
      body.push((65 + (i % 17)).to_byte())
    }""",
}

HEAD = """// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Streams written by libbrotli — the implementation inside Node's `zlib` —
/// pinned as they came out.
///
/// Every one of them must decode to exactly the bytes that were compressed. This
/// is harder than it sounds for brotli: at quality 11 the encoder names words in
/// the static dictionary instead of spelling them, so a reader that has the
/// container right and the dictionary wrong decodes most of a file correctly and
/// then emits the wrong bytes for a paragraph. These frames are what catches it.
///
///     python3 scripts/brotli_vectors.py
///
/// regenerates this file. It needs `node` on the path.
"""


def chunks(text, width=64):
    return [text[i:i + width] for i in range(0, len(text), width)]


def identifier(frame):
    return "%s_%s" % (frame["name"], frame["tag"])


def main():
    out = subprocess.run(["node", "-e", SCRIPT], capture_output=True, text=True, check=True)
    frames = json.loads(out.stdout)
    lines = [HEAD]
    for frame in frames:
        name = identifier(frame)
        lines.append("///|\n/// %s at quality %d, window %d.\n" % (frame["name"], frame["quality"], frame["window"]))
        lines.append("fn frame_%s() -> Bytes {\n  @base16.decode_lossy(\n" % name)
        lines.append(" +\n".join('    "%s"' % c for c in chunks(frame["frame"])))
        lines.append(",\n  )\n}\n")
    for body in sorted({frame["name"] for frame in frames}):
        lines.append("///|\nfn body_%s() -> Bytes {\n" % body)
        if body in GENERATORS:
            lines.append(GENERATORS[body] + "\n  Bytes::from_array(body)\n}\n")
        else:
            hexed = next(f["body"] for f in frames if f["name"] == body)
            if hexed == "":
                lines.append("  Bytes::new(0)\n}\n")
                continue
            lines.append("  @base16.decode_lossy(\n")
            lines.append(" +\n".join('    "%s"' % c for c in chunks(hexed)))
            lines.append(",\n  )\n}\n")
    # One test per stream rather than one test with seventy-four assertions:
    # when one of these fails, the name is the whole diagnosis.
    for frame in frames:
        name = identifier(frame)
        lines.append("///|\n")
        lines.append('test "%s at quality %d, window %d, %s" {\n' % (
            frame["name"], frame["quality"], frame["window"], frame["tag"]))
        lines.append("  assert_eq(@brotli.unbrotli(frame_%s()[:]), body_%s())\n" % (name, frame["name"]))
        lines.append("}\n")
    path = ROOT / "src" / "brotli" / "interop_test.mbt"
    path.write_text("".join(lines), encoding="utf-8", newline="\n")
    total = sum(len(f["frame"]) // 2 for f in frames)
    print("wrote %s (%d streams, %d bytes)" % (path, len(frames), total))


if __name__ == "__main__":
    main()
