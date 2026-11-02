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
fn write(parts : Array[Bytes], level : Int32) -> Bytes {
  let writer = @lzma.Writer::new(level~)
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
  let reader = @lzma.Reader::new()
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
/// There are no blocks to align to, so the cut can fall anywhere: the same body
/// cut anywhere is the same stream, byte for byte.
test "a body fed in random pieces is one stream" {
  for kind in 0..<6 {
    let data = sample(kind)
    let want = write([data], 6)
    for seed in [1, 7, 99, 12345] {
      assert_eq(write(pieces(data, seed), 6), want)
    }
  }
}

///|
test "a stream fed in random pieces reads back" {
  for kind in [2, 3, 4, 5] {
    let data = sample(kind)
    let packed = write(pieces(data, 7), 6)
    for seed in [1, 7, 99, 12345] {
      assert_eq(read(pieces(packed, seed)), data)
    }
    // And the one-shot reader, which never saw a piece.
    assert_eq(@lzma.unlzma(packed[:]), data)
  }
}

///|
/// Every level is a dictionary size, and a stream written at one has to read back
/// at that level's window: the writer's chains may only reach that far.
test "every level round-trips through the pair" {
  let data = sample(3)
  for level in [0, 1, 3, 6, 9] {
    assert_eq(read(pieces(write(pieces(data, 3), level), 5)), data)
  }
}
