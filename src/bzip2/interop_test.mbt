// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A bzip2 stream written by Python's `bz2`, pinned as it came out.
///
/// Python calls libbz2, which is the reference implementation of the format,
/// so this is the only judge that matters. Python also picks its own table
/// counts and its own block boundaries, which our encoder does not have to
/// agree with: a reader that only understood its own output would learn
/// nothing here.
///
///     python3 scripts/interop.py
///
/// regenerates this file.

///|
fn python_body() -> Bytes {
  let out : Array[Byte] = []
  for _ in 0..<20 {
    for b in "the quick brown fox jumps over the lazy dog. " {
      out.push((b.to_int() % 256).to_byte())
    }
  }
  Bytes::from_array(out)
}

///|
test "python's bzip2 stream reads back" {
  let packed = @base16.decode_lossy(
    "425a68363141592653597f3fdc3c00017b918040013ffffff03000b80a343400000146868000000a5526a6982608cd4db51f84c13b1304e24d09913426f27427e93893b93227713526c27927a1352664fe2644d84c13c9332732684f44cc9d89fe4d4998982609d0abd93d93e0bb9229c28483f9fee1e0",
  )
  assert_eq(@bzip2.bunzip2(packed[:]), python_body())
}
