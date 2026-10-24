#!/usr/bin/env python3
"""Regenerate `sevenz/interop_test.mbt` from archives 7-Zip wrote.

    python3 scripts/sevenz_vectors.py

The archives are the ones shipped with the py7zr project as test data, which were
written by 7-Zip itself -- so reading them is a check against the format's
reference implementation rather than against our own writer. They are pinned as
hex rather than copied so that the test file is one file and the repository does
not grow a binary directory.

Fetch them with:

    git clone --depth 1 https://github.com/miurahr/py7zr .temp-ref/py7zr
"""

import os
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / ".temp-ref" / "py7zr" / "tests" / "data"

# One archive per shape worth pinning: the plainest form, the three codecs that
# are implemented, a filter chain, an empty archive, a solid one, and one whose
# names are not ASCII.
CASES = [
    ("empty.7z", "an archive of nothing at all"),
    ("lzma_1.7z", "one file, one LZMA folder"),
    ("copy.7z", "one file, stored — the shape that has a coder with no properties"),
    ("deflate.7z", "two files and a directory, with the header itself compressed"),
    ("lzma2delta_1.7z", "an LZMA2 folder followed by a delta filter"),
    ("umlaut-solid.7z", "a name outside ASCII, which only survives as UTF-16"),
    ("zerosize.7z", "members with no content of their own"),
    ("solid.7z", "three files in one folder, so the substream table is used"),
]

HEAD = """// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Archives written by 7-Zip, pinned as they came out.
///
/// These are the ones shipped with the py7zr project as test data. 7-Zip wrote
/// them, which is the point: our own writer can agree with our own reader about
/// a mistake, and only somebody else's bytes can say otherwise. Each read below
/// has to pass the checksums the archive itself carries, so "it decodes" means
/// "it decodes to what 7-Zip said it would".
///
///     python3 scripts/sevenz_vectors.py
///
/// regenerates this file.

"""


def body(name):
    return """///|
fn pinned_%s() -> Bytes {
  @base16.decode_lossy(
%s
  )
}

""" % (name.replace(".", "_").replace("-", "_"),
       ' +\n'.join('    "%s"' % chunk
                   for chunk in _chunks((SOURCE / name).read_bytes())))


def _chunks(data, width=64):
    hexed = data.hex()
    return [hexed[i:i + width] for i in range(0, len(hexed), width)]


def main():
    missing = [n for n, _ in CASES if not (SOURCE / n).exists()]
    if missing:
        raise SystemExit(
            "missing fixtures: %s\nclone py7zr into .temp-ref/ first" % ", ".join(missing)
        )
    out = [HEAD]
    for name, why in CASES:
        out.append("///|\n/// %s.\n" % why)
        out.append(body(name))
    out.append("///|\n/// Every one of them has to read, and the checksums inside them have\n/// to agree with what came out.\ntest \"archives written by 7-Zip read back\" {\n")
    for name, _ in CASES:
        out.append("  {  // %s\n" % name)
        out.append("    let members = @sevenz.un7z(pinned_%s()[:])\n" % name.replace(".", "_").replace("-", "_"))
        if name == "empty.7z":
            out.append("    assert_eq(members.length(), 0)\n")
        else:
            out.append("    assert_true(members.length() > 0)\n")
        out.append("  }\n")
    out.append("}\n")
    path = ROOT / "sevenz" / "interop_test.mbt"
    path.write_text("".join(out), encoding="utf-8", newline="\n")
    total = sum((SOURCE / n).stat().st_size for n, _ in CASES)
    print("wrote %s (%d archives, %d bytes)" % (path, len(CASES), total))


if __name__ == "__main__":
    main()
