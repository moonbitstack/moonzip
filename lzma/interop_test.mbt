// Copyright 2026 Leo Cheng
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
    for b in "the quick brown fox jumps over the lazy dog. " {
      out.push((b.to_int() % 256).to_byte())
    }
  }
  Bytes::from_array(out)
}

///|
test "python's lzma stream reads back" {
  let packed = @base16.decode_lossy(
    "5d00008000ffffffffffffffff003a1a08ce76c7e5e9d60734c3d10ebfce55e1aabde0e48f9801dd8de507549e65255f273a6a7eb4d3490389ced47d3cff9ade361cac116556580937ffffd87a0000",
  )
  assert_eq(@lzma.unlzma(packed[:]), body())
}
