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
fn write(parts : Array[Bytes]) -> Bytes {
  let writer = @snappy.Writer::new()
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
  let reader = @snappy.Reader::new()
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
/// A chunk is a chunk whichever push delivered it: the same body cut anywhere is
/// the same stream.
test "a body fed in random pieces is one stream" {
  for kind in 0..<6 {
    let data = body(kind)
    let want = @snappy.frame(data[:])
    for seed in [1, 7, 99, 12345] {
      assert_eq(write(pieces(data, seed)), want)
    }
  }
}

///|
test "a stream fed in random pieces reads back" {
  for kind in [2, 3, 4, 5] {
    let data = body(kind)
    let packed = @snappy.frame(data[:])
    for seed in [1, 7, 99, 12345] {
      assert_eq(read(pieces(packed, seed)), data)
    }
  }
}

///|
/// Two hundred kilobytes is four chunks, and the first has to leave the writer
/// while the body is still arriving.
test "a body of several chunks goes out a chunk at a time" {
  let data = body(5)
  let writer = @snappy.Writer::new()
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
  assert_true(first > 0)
  for b in writer.finish() {
    out.push(b)
  }
  assert_eq(read([Bytes::from_array(out)]), data)
}

///|
/// A stream another implementation wrote, read a piece at a time. The writer's
/// own output proves nothing about a reader that was written against it: what
/// this pins is the chunking, the header and the checksums Python's encoder
/// chooses, which are not the ones this package does.
test "a stream another implementation wrote reads back" {
  let packed = @base16.decode_lossy(
    "ff060000734e61507059003c000097dc9081b4017874686520717569636b2062726f776e20666f78206a756d7073206f76657220011f206c617a7920646f672e050efe2d00ee2d000d2d",
  )
  let body : Array[Byte] = []
  for _ in 0..<4 {
    for b in "the quick brown fox jumps over the lazy dog. " {
      body.push((b.to_int() % 256).to_byte())
    }
  }
  let want = Bytes::from_array(body)
  for seed in [1, 7, 99] {
    assert_eq(read(pieces(packed, seed)), want)
  }
}
