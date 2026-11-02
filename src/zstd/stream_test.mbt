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
  let writer = @zstd.Writer::new()
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
  let reader = @zstd.Reader::new()
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
/// A block is a block whichever push delivered it. The one-shot form writes the
/// body's size into the header, which a writer that is still receiving cannot
/// know, so the comparison is against the same writer fed once.
test "a body fed in random pieces is one frame" {
  for kind in 0..<6 {
    let data = sample(kind)
    let want = write([data])
    for seed in [1, 7, 99, 12345] {
      assert_eq(write(pieces(data, seed)), want)
    }
  }
}

///|
/// Reading is the half that has to accept both spellings of a header: the one a
/// writer that knows the size produces, and the one it does not.
test "a frame written in one call reads back in pieces" {
  for kind in [2, 3, 4, 5] {
    let data = sample(kind)
    let packed = @zstd.zstd(data[:])
    for seed in [1, 7, 99, 12345] {
      assert_eq(read(pieces(packed, seed)), data)
    }
  }
}

///|
test "a frame written in pieces reads back in pieces" {
  for kind in [2, 3, 4, 5] {
    let data = sample(kind)
    let packed = write(pieces(data, 7))
    assert_eq(read(pieces(packed, 99)), data)
    assert_eq(@zstd.unzstd(packed[:]), data)
  }
}

///|
/// Two hundred kilobytes is four blocks, and the first has to leave the writer
/// while the body is still arriving.
test "a body of several blocks goes out a block at a time" {
  let data = sample(5)
  let writer = @zstd.Writer::new()
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
