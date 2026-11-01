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
/// The search puts the cut where the stream changes kind. Two hundred commands of
/// one symbol followed by two hundred of another has a seam at 200; a single code
/// spends four hundred bits on it, two codes spend ten.
test "the split search finds the seam" {
  let codes = FixedArray::make(400, 0)
  for i in 0..<400 {
    codes[i] = if i < 200 { 5 } else { 300 }
  }
  let cut = best_cut(codes, 400)
  // The search samples a grid rather than every index, so the seam is approached
  // rather than hit exactly.
  assert_true(cut > 190 && cut < 210)
}

///|
/// A stream that is one symbol throughout has nothing to gain from a second code,
/// and the description of that code is a real cost. The search must decline.
test "a uniform command stream is not split" {
  let codes = FixedArray::make(300, 7)
  assert_eq(best_cut(codes, 300), 300)
}

///|
/// Both paths write a stream that reads back, whatever the search decides.
test "the split path still reads back" {
  let body = split_body()
  let flat = compress(body[:], 22, 1 << 24)
  let split = compress(body[:], 22, 1 << 24, split=true)
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
