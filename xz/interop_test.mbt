// Copyright 2026 Leo Cheng
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
    for b in "the quick brown fox jumps over the lazy dog. " {
      out.push((b.to_int() % 256).to_byte())
    }
  }
  Bytes::from_array(out)
}

///|
test "python's xz stream reads back" {
  let packed = @base16.decode_lossy(
    "fd377a585a000004e6d6b4460200210116000000742fe5a3e00707003c5d003a1a08ce76c7e5e9d60734c3d10ebfce55e1aabde0e48f9801dd8de507549e65255f273a6a7eb4d3490389ced47d3cff9ade361cac116555fe7c0000007504bdbbcca1246b000158880e00000027d2c142b1c467fb020000000004595a",
  )
  assert_eq(@xz.unxz(packed[:]), body())
}
