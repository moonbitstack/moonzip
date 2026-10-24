#!/usr/bin/env python3
"""Pin what other implementations write, so our readers are tested on it.

    python3 scripts/interop.py

Writes `zip/interop_test.mbt`. `scripts/conformance.py` covers the other
direction -- our output handed to Python -- and this covers the shapes only a
foreign writer produces: a data descriptor, a forced Zip64 header. A reader that
only ever sees its own output can be wrong for years and never notice.
"""

import bz2 as bz2_mod
import io
import lzma as lzma_mod
import os
import tarfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MEMBERS = [("one.txt", b"the first member"), ("two/three.txt", b"a" * 500)]
STAMP = (2020, 1, 2, 3, 4, 6)


class Sink:
    """A stream Python's zipfile cannot seek on, which makes it write descriptors."""

    def __init__(self, raw):
        self.raw = raw

    def write(self, data):
        return self.raw.write(data)

    def tell(self):
        raise OSError("not seekable")

    def seek(self, *args):
        raise OSError("not seekable")

    def flush(self):
        pass


def build(streamed=False, zip64=False):
    raw = io.BytesIO()
    target = Sink(raw) if streamed else raw
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, body in MEMBERS:
            info = zipfile.ZipInfo(name, STAMP)
            if zip64:
                with archive.open(info, "w", force_zip64=True) as handle:
                    handle.write(body)
            else:
                archive.writestr(info, body)
    return raw.getvalue()


TEMPLATE = '''// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Archives written by Python's `zipfile`, pinned as they came out.
///
/// This is the other direction from `scripts/conformance.py`: that script hands
/// our archives to Python, and these three were handed to us. They are the
/// shapes a foreign writer produces that a reader of our own output would never
/// see — a data descriptor, a forced Zip64 header, and the plain form.
///
///     python3 scripts/interop.py
///
/// regenerates this file.

///|
fn pinned(name : String) -> Bytes {
__ARMS__
  abort("no pinned archive named \\{name}")
}

///|
/// What every one of the three archives holds, read through both readers.
fn check(archive : Bytes) -> Unit raise {
  let back = @zip.unzip(archive[:])
  assert_eq(back.map(e => e.name), ["one.txt", "two/three.txt"])
  assert_eq(back[0].data, b"the first member")
  assert_eq(back[1].data, Bytes::make(500, b'a'))
  // And from the front, which is the only way a reader that is receiving the
  // archive rather than holding it can go.
  let reader = @zip.Reader::new(archive[:])
  let seen : Array[String] = []
  while true {
    match reader.next() {
      None => break
      Some(entry) => seen.push(entry.name)
    }
  }
  assert_eq(seen, ["one.txt", "two/three.txt"])
}

///|
test "python's plain archive reads back" {
  check(pinned("plain"))
}

///|
test "python's streamed archive reads back, descriptor and all" {
  check(pinned("streamed"))
}

///|
test "python's zip64 archive reads back" {
  check(pinned("wide"))
}
'''


TAR_TEMPLATE = '''// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Archives written by Python's `tarfile`, pinned as they came out.
///
/// The three formats a tar header may be in, which is what a reader has to
/// handle: ustar, pax (with its extended headers for long names) and the GNU
/// format with its own long-name records.
///
///     python3 scripts/interop.py
///
/// regenerates this file.

///|
fn pinned(name : String) -> Bytes {
__ARMS__
  abort("no pinned archive named \{name}")
}

///|
/// A name longer than a hundred bytes, which is what pax and GNU each have their
/// own answer for.
fn long_name() -> String {
  "a-directory-name-long-enough-to-not-fit/another-one-deep/and-then-a-third/a-member-with-a-rather-long-name.txt"
}

///|
/// What all three archives hold, read through the one reader.
fn check(archive : Bytes) -> Unit raise {
  let back = @tar.untar(archive[:])
  assert_eq(back[0].name, "one.txt")
  assert_eq(back[0].data, b"the first member")
  assert_eq(back[1].name, long_name())
  assert_eq(back[1].data, Bytes::make(500, b'a'))
  assert_eq(back[2].kind, @tar.Tarball::Directory)
  assert_eq(back[3].kind, @tar.Tarball::Symlink)
  assert_eq(back[3].link, "one.txt")
}

///|
test "python's ustar archive reads back" {
  check(pinned("ustar"))
}

///|
test "python's pax archive reads back" {
  check(pinned("pax"))
}

///|
test "python's gnu archive reads back" {
  check(pinned("gnu"))
}
'''


def build_tar(fmt):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=fmt) as archive:
        for name, body in [("one.txt", b"the first member"), (LONG_NAME, b"a" * 500)]:
            info = tarfile.TarInfo(name)
            info.size = len(body)
            info.mtime = 1700000000
            archive.addfile(info, io.BytesIO(body))
        info = tarfile.TarInfo("empty")
        info.type = tarfile.DIRTYPE
        info.mode = 0o755
        archive.addfile(info)
        info = tarfile.TarInfo("link")
        info.type = tarfile.SYMTYPE
        info.linkname = "one.txt"
        archive.addfile(info)
    return raw.getvalue()


LONG_NAME = (
    "a-directory-name-long-enough-to-not-fit/another-one-deep/"
    "and-then-a-third/a-member-with-a-rather-long-name.txt"
)


def write_tar():
    shapes = [
        ("ustar", build_tar(tarfile.USTAR_FORMAT)),
        ("pax", build_tar(tarfile.PAX_FORMAT)),
        ("gnu", build_tar(tarfile.GNU_FORMAT)),
    ]
    arms = "\n".join(
        '  if name == "{}" {{\n    return @base16.decode_lossy(\n      "{}",\n    )\n  }}'.format(
            name, blob.hex()
        )
        for name, blob in shapes
    )
    path = os.path.join(ROOT, "tar", "interop_test.mbt")
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(TAR_TEMPLATE.replace("__ARMS__", arms))
    print("wrote {} ({} bytes of vectors)".format(path, sum(len(b) for _, b in shapes)))


LZMA_TEMPLATE = """// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A `.lzma` stream written by Python, pinned as it came out.
///
/// Python writes the length as unknown and ends with a marker instead, which is
/// a path our own encoder never takes: it always states the size. A reader that
/// only ever saw its own output would not know it existed.
///
///     python3 scripts/interop.py
///
/// regenerates this file.

///|
fn body() -> Bytes {
  let out : Array[Byte] = []
  for _ in 0..<40 {
    for b in \"the quick brown fox jumps over the lazy dog. \" {
      out.push((b.to_int() % 256).to_byte())
    }
  }
  Bytes::from_array(out)
}

///|
test \"python's lzma stream reads back\" {
  let packed = @base16.decode_lossy(
__HEX__
  )
  assert_eq(@lzma.unlzma(packed[:]), body())
}
"""


def write_lzma():
    payload = b"the quick brown fox jumps over the lazy dog. " * 40
    blob = lzma_mod.compress(payload, format=lzma_mod.FORMAT_ALONE, preset=6)
    hexed = blob.hex()
    lines = '    "' + hexed + '",'
    path = os.path.join(ROOT, "lzma", "interop_test.mbt")
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(LZMA_TEMPLATE.replace("__HEX__", lines))
    print("wrote {} ({} bytes)".format(path, len(blob)))


XZ_TEMPLATE = """// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// An xz stream written by Python, pinned as it came out.
///
/// Python's encoder chooses a different LZMA2 chunking and a different dictionary
/// from ours, and writes the same body; a reader that only ever saw its own
/// output would learn nothing from this one.
///
///     python3 scripts/interop.py
///
/// regenerates this file.

///|
fn body() -> Bytes {
  let out : Array[Byte] = []
  for _ in 0..<40 {
    for b in \"the quick brown fox jumps over the lazy dog. \" {
      out.push((b.to_int() % 256).to_byte())
    }
  }
  Bytes::from_array(out)
}

///|
test \"python's xz stream reads back\" {
  let packed = @base16.decode_lossy(
    \"__HEX__\",
  )
  assert_eq(@xz.unxz(packed[:]), body())
}
"""


def write_xz():
    payload = b"the quick brown fox jumps over the lazy dog. " * 40
    blob = lzma_mod.compress(payload, format=lzma_mod.FORMAT_XZ)
    path = os.path.join(ROOT, "xz", "interop_test.mbt")
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(XZ_TEMPLATE.replace("__HEX__", blob.hex()))
    print("wrote {} ({} bytes)".format(path, len(blob)))


BZIP2_HEAD = [
    "// Copyright 2026 Leo Cheng",
    "// SPDX-License-Identifier: Apache-2.0",
    "",
    "///|",
    "/// A bzip2 stream written by Python's `bz2`, pinned as it came out.",
    "///",
    "/// Python calls libbz2, which is the reference implementation of the format,",
    "/// so this is the only judge that matters. Python also picks its own table",
    "/// counts and its own block boundaries, which our encoder does not have to",
    "/// agree with: a reader that only understood its own output would learn",
    "/// nothing here.",
    "///",
    "///     python3 scripts/interop.py",
    "///",
    "/// regenerates this file.",
    "",
    "///|",
    "fn python_body() -> Bytes {",
    "  let out : Array[Byte] = []",
    "  for _ in 0..<20 {",
    '    for b in "the quick brown fox jumps over the lazy dog. " {',
    "      out.push((b.to_int() % 256).to_byte())",
    "    }",
    "  }",
    "  Bytes::from_array(out)",
    "}",
    "",
    "///|",
    'test "python\'s bzip2 stream reads back" {',
    "  let packed = @base16.decode_lossy(",
]


def write_bzip2():
    payload = b"the quick brown fox jumps over the lazy dog. " * 20
    blob = bz2_mod.compress(payload, 6)
    lines = list(BZIP2_HEAD)
    lines.append('    "{}",'.format(blob.hex()))
    lines += [
        "  )",
        "  assert_eq(@bzip2.bunzip2(packed[:]), python_body())",
        "}",
    ]
    path = os.path.join(ROOT, "bzip2", "interop_test.mbt")
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(lines) + "\n")
    print("wrote {} ({} bytes)".format(path, len(blob)))


def main():
    shapes = [
        ("plain", build()),
        ("streamed", build(streamed=True)),
        ("wide", build(zip64=True)),
    ]
    arms = "\n".join(
        '  if name == "{}" {{\n    return @base16.decode_lossy(\n      "{}",\n    )\n  }}'.format(
            name, blob.hex()
        )
        for name, blob in shapes
    )
    path = os.path.join(ROOT, "zip", "interop_test.mbt")
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(TEMPLATE.replace("__ARMS__", arms))
    print("wrote {} ({} bytes of vectors)".format(path, sum(len(b) for _, b in shapes)))
    write_tar()
    write_lzma()
    write_xz()
    write_bzip2()


if __name__ == "__main__":
    main()
