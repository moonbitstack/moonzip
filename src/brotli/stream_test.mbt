// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Split at the offsets a fixed-seed generator picks, so a failure is a boundary
/// that can be visited again rather than one that existed for a moment.
fn pieces(data : Bytes, seed : Int32) -> Array[Bytes] {
  let out : Array[Bytes] = []
  let mut state = seed
  let mut at = 0
  while at < data.length() {
    state = (state * 1103515245 + 12345) & 0x7FFFFFF
    let take = 1 + state % 131
    let stop = if data.length() - at < take { data.length() } else { at + take }
    out.push(data[at:stop].to_owned())
    at = stop
  }
  out
}

///|
fn write(parts : Array[Bytes], quality : Int32) -> Bytes {
  let writer = @brotli.Writer::new(quality~)
  let out : Array[Byte] = []
  for part in parts {
    for b in writer.push(part[:]) {
      out.push(b)
    }
  }
  for b in writer.finish() {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
fn read(parts : Array[Bytes]) -> Bytes raise @moonzip.Refused {
  let reader = @brotli.Reader::new()
  let out : Array[Byte] = []
  for part in parts {
    for b in reader.push(part[:]) {
      out.push(b)
    }
  }
  for b in reader.finish() {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// A meta-block is written whole, so a cut that falls inside one changes nothing
/// but the waiting: the same body cut anywhere is the same stream.
test "a body fed in random pieces is one stream" {
  for kind in 0..<6 {
    let data = sample(kind)
    let want = write([data], 9)
    for seed in [1, 7, 99, 12345] {
      assert_eq(write(pieces(data, seed), 9), want)
    }
  }
}

///|
test "a stream fed in random pieces reads back" {
  for kind in [2, 3, 4, 5] {
    let data = sample(kind)
    let packed = write(pieces(data, 7), 9)
    for seed in [1, 7, 99, 12345] {
      assert_eq(read(pieces(packed, seed)), data)
    }
    assert_eq(@brotli.unbrotli(packed[:]), data)
  }
}

///|
/// Quality changes what the writer searches for and nothing about the shape of
/// the stream, so every quality reads back through the same pair.
test "every quality round-trips through the pair" {
  let data = sample(3)
  for quality in [0, 1, 2, 5, 9, 11] {
    let packed = write(pieces(data, 3), quality)
    assert_eq(read(pieces(packed, 5)), data)
  }
}
