// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Split at the offsets a fixed-seed generator picks.
///
/// The point of a fixed seed is that a failure can be run again: the same bytes
/// land on the same boundaries, and the boundary that broke is the one in the
/// message rather than one that existed for a moment.
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
  let writer = @lz4.Writer::new(level~)
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
  let reader = @lz4.Reader::new()
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
/// The same body cut at any boundary is the same frame: a block is a block
/// whichever push delivered it.
test "a body fed in random pieces is one frame" {
  for kind in 0..<6 {
    let data = body(kind)
    let want = @lz4.frame(data[:])
    for seed in [1, 7, 99, 12345] {
      assert_eq(write(pieces(data, seed), 0), want)
    }
  }
}

///|
/// And reading it back gives the body, again whatever the pieces were.
test "a frame fed in random pieces reads back" {
  for kind in [2, 3, 4, 5] {
    let data = body(kind)
    let packed = @lz4.frame(data[:])
    for seed in [1, 7, 99, 12345] {
      assert_eq(read(pieces(packed, seed)), data)
    }
  }
}

///|
/// A body longer than a block is where a writer that gathered everything would
/// show: the first block has to be handed over while the body is still arriving.
test "a body of several blocks goes out a block at a time" {
  let data = body(5)
  let writer = @lz4.Writer::new()
  let out : Array[Byte] = []
  let mut first = 0
  let mut at = 0
  while at < data.length() {
    let stop = if data.length() - at < 65536 {
      data.length()
    } else {
      at + 65536
    }
    let made = writer.push(data[at:stop])
    if first == 0 {
      first = made.length()
    }
    for b in made {
      out.push(b)
    }
    at = stop
  }
  // Sixty-four kilobytes in, a whole block has already gone out.
  assert_true(first > 0)
  for b in writer.finish() {
    out.push(b)
  }
  assert_eq(read([Bytes::from_array(out)]), data)
}
