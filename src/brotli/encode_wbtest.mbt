// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A body with many commands and a little variety, so the two halves of the
/// command stream can choose different codes.
fn split_body() -> Bytes {
  let out : Array[Byte] = []
  for i in 0..<3000 {
    for b in b"alpha beta gamma delta " {
      out.push(b)
    }
    out.push((0x30 + i / 100 % 10).to_byte())
    out.push((0x30 + i / 10 % 10).to_byte())
    out.push((0x30 + i % 10).to_byte())
    out.push(b' ')
  }
  Bytes::from_array(out)
}

///|
/// The split path is a different stream from the unsplit one, and each reads
/// back. It also confirms the split is actually taken, so a refactor that
/// quietly disabled it would fail here rather than pass on a byte-identical
/// output.
test "block splitting changes the stream and still reads back" {
  let body = split_body()
  let flat = compress(body[:], 22, 1 << 24)
  let split = compress(body[:], 22, 1 << 24, split=true)
  assert_not_eq(flat, split)
  assert_eq(unbrotli(flat[:]), body)
  assert_eq(unbrotli(split[:]), body)
}

///|
/// A body too small to hold two commands is not split, and must still read back —
/// the guard that keeps a one-command block from asking for a second type.
test "a tiny block is not split and still reads back" {
  let body = b"hi"
  let flat = compress(body[:], 22, 1 << 24)
  let split = compress(body[:], 22, 1 << 24, split=true)
  assert_eq(flat, split)
  assert_eq(unbrotli(split[:]), body)
}
