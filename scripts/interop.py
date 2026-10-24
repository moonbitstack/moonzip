#!/usr/bin/env python3
"""Pin what other implementations write, so our readers are tested on it.

    python3 scripts/interop.py

Writes `zip/interop_test.mbt`. `scripts/conformance.py` covers the other
direction -- our output handed to Python -- and this covers the shapes only a
foreign writer produces: a data descriptor, a forced Zip64 header. A reader that
only ever sees its own output can be wrong for years and never notice.
"""

import io
import os
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
fn pinned(name : String) -> Bytes raise {
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


def main():
    shapes = [
        ("plain", build()),
        ("streamed", build(streamed=True)),
        ("wide", build(zip64=True)),
    ]
    arms = "\n".join(
        '  if name == "{}" {{\n    return @base16.decode_lossy("{}")\n  }}'.format(
            name, blob.hex()
        )
        for name, blob in shapes
    )
    path = os.path.join(ROOT, "zip", "interop_test.mbt")
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(TEMPLATE.replace("__ARMS__", arms))
    print("wrote {} ({} bytes of vectors)".format(path, sum(len(b) for _, b in shapes)))


if __name__ == "__main__":
    main()
