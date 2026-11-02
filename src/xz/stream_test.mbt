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
  let writer = @xz.Writer::new(level~)
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
  let reader = @xz.Reader::new()
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
/// A chunk is the unit, and a chunk is placed by size rather than by where the
/// caller happened to stop, so the same body cut anywhere is the same stream.
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
    assert_eq(@xz.unxz(packed[:]), data)
  }
}

///|
/// The check is a choice, and a reader that trusts the block's stamp has to read
/// what each one writes.
test "each check reads back" {
  let data = sample(3)
  for check in [@xz.Check::None, @xz.Check::Crc32, @xz.Check::Crc64] {
    let writer = @xz.Writer::new(check~)
    let packed = writer.push(data[:]) + writer.finish()
    assert_eq(read(pieces(packed, 11)), data)
    assert_eq(@xz.unxz(packed[:]), data)
  }
}

///|
/// An empty body is a stream with no block at all, which the index has to say.
test "an empty body is a stream" {
  let packed = write([], 6)
  assert_eq(@xz.unxz(packed[:]), b"")
  assert_eq(read([packed]), b"")
}
