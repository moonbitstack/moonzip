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

///|
/// Identical contexts are one code, not sixty-four. Everything else would be
/// paying for a map that routes every context to the same place.
test "contexts that look alike share one code" {
  let hist = FixedArray::make(64 * 256, 0)
  for c in 0..<64 {
    hist[c * 256 + 65] = 100
  }
  let (groups, _) = group_contexts(hist)
  assert_eq(groups, 1)
}

///|
/// Two families of contexts that spell different letters want different codes,
/// and the map has to send them to different ones.
test "two context families get two codes" {
  let hist = FixedArray::make(64 * 256, 0)
  for c in 0..<32 {
    hist[c * 256 + 65] = 100
  }
  for c in 32..<64 {
    hist[c * 256 + 66] = 100
  }
  let (groups, map) = group_contexts(hist)
  assert_true(groups >= 2)
  assert_true(map[0] != map[63])
}

///|
/// A body with English letter statistics and no long repeats: every letter is
/// chosen from a small table of plausible followers, so the text has the local
/// structure a context model is for while the match finder has little to take.
fn bigram_body() -> Bytes {
  let follows : Array[Bytes] = [
    b"ntrl", b"ear", b"hto", b"eio", b"rnsa", b"orat", b"ehir", b"eai", b"tns", b"uoa",
    b"eian", b"eal", b"eao", b"tdo", b"nurf", b"ero", b"u", b"eato", b"teah", b"hieo",
    b"rntl", b"eio", b"ahei", b"ptr", b"o e", b"e",
  ]
  let out : Array[Byte] = []
  for i in 0..<900 {
    let mut state : UInt32 = 20261101U + i.reinterpret_as_uint()
    let mut letter = 0
    for _ in 0..<70 {
      state = state * 1103515245U + 12345U
      let pool = follows[letter]
      letter = pool[(state >> 16).reinterpret_as_int() % pool.length()].to_int() -
        0x61
      out.push((0x61 + letter).to_byte())
    }
    out.push(b' ')
  }
  Bytes::from_array(out)
}

///|
/// Modelling literals by context changes the stream and shrinks it, and both
/// forms read back.
test "literal contexts change the stream and shrink it" {
  let body = bigram_body()
  let flat = compress(body[:], 22, 1 << 24)
  let modelled = compress(body[:], 22, 1 << 24, contexts=true)
  assert_not_eq(flat, modelled)
  assert_eq(unbrotli(flat[:]), body)
  assert_eq(unbrotli(modelled[:]), body)
  assert_true(modelled.length() < flat.length())
}

///|
/// The search is exact about what a second code costs, so asking for context
/// modelling can never produce a larger stream than declining it. That is the
/// property worth pinning: an estimate lenient enough to accept a losing split
/// shows up here as a body that got bigger.
test "context modelling never costs bytes" {
  let bodies : Array[Bytes] = [
    bigram_body(),
    Bytes::from_array(Array::make(5000, b'x')),
    Bytes::from_array(Array::make(3000, b'a')),
  ]
  for body in bodies {
    let flat = compress(body[:], 22, 1 << 24)
    let modelled = compress(body[:], 22, 1 << 24, contexts=true)
    assert_true(modelled.length() <= flat.length())
    assert_eq(unbrotli(modelled[:]), body)
  }
}
