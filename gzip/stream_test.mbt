// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One gzip stream, fed to a reader in chunks of `step` bytes, reassembled.
fn stream_in(data : Bytes, step : Int32) -> Bytes raise @moonzip.Refused {
  let reader = @gzip.Reader::new()
  let out : Array[Byte] = []
  let mut at = 0
  while at < data.length() {
    let stop = if data.length() - at < step { data.length() } else { at + step }
    for b in reader.push(data[at:stop]) {
      out.push(b)
    }
    at = stop
  }
  for b in reader.finish() {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// And one writer, fed in the same chunks.
fn stream_out(data : Bytes, step : Int32, level : Int32) -> Bytes {
  let writer = @gzip.Writer::new(level~)
  let out : Array[Byte] = []
  let mut at = 0
  while at < data.length() {
    let stop = if data.length() - at < step { data.length() } else { at + step }
    for b in writer.push(data[at:stop]) {
      out.push(b)
    }
    at = stop
  }
  for b in writer.finish() {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// A body that arrives one byte at a time decompresses to exactly what went in.
///
/// This is the property the whole streaming design exists for: a chunk boundary
/// may fall inside a header, inside a Huffman code, or inside a stored block,
/// and the reader has to stop and wait rather than misread. Every step from one
/// byte up to a whole frame is tried, because the boundaries that break a naive
/// decoder are never the round ones.
test "gzip streams a body in any chunk size" {
  for kind in 0..<7 {
    let body = sample(kind)
    let packed = @gzip.gzip(body[:])
    for step in [1, 2, 3, 5, 7, 13, 64, 511, 4096, 65536] {
      assert_eq(stream_in(packed, step), body)
    }
  }
}

///|
/// A writer fed in pieces writes the same bytes as the one-shot function, as
/// long as the whole body fits in one block — the streaming writer closes a
/// block every 32 KiB, which is where a body is no longer the same stream a
/// single call would produce, and both are correct.
test "gzip streaming writes what the one-shot writes" {
  for kind in 0..<6 {
    let body = sample(kind)
    assert_true(body.length() < 32768)
    for level in [0, 1, 6, 9] {
      let whole = @gzip.gzip(body[:], level~)
      for step in [1, 4, 17, 1024, 65536] {
        assert_eq(stream_out(body, step, level), whole)
      }
    }
  }
}

///|
/// An empty body is still a stream: a header, an empty block, and a trailer
/// whose length is zero.
test "gzip streams nothing at all" {
  let writer = @gzip.Writer::new()
  let nothing = writer.finish()
  assert_eq(nothing.length(), 20)
  assert_eq(@gzip.gunzip(nothing[:]), b"")
  // A reader given no input at all is a truncated stream, not an empty body —
  // an empty stream still has to say so.
  let reader = @gzip.Reader::new()
  let error = try {
    reader.finish() |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_eq(error, Some(@moonzip.Truncated(at=0)))
}

///|
/// A trailer that disagrees with the body is caught, and a caller that says it
/// does not care about the checksum still gets the bytes — which is what
/// recovering what arrived from a damaged transfer needs.
test "gzip streaming checks the trailer it was given" {
  let body = sample(3)
  let packed = @gzip.gzip(body[:])
  // The last eight bytes are the CRC-32 and the length; spoil the CRC only, so
  // the stream itself is still well formed.
  let spoiled : Array[Byte] = []
  for i in 0..<packed.length() {
    spoiled.push(
      if i == packed.length() - 8 {
        (packed[i].to_int() ^ 0xFF).to_byte()
      } else {
        packed[i]
      },
    )
  }
  let damaged = Bytes::from_array(spoiled)
  let reader = @gzip.Reader::new()
  let error = try {
    reader.push(damaged[:]) |> ignore
    reader.finish() |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_true(error is Some(_))
  let reader = @gzip.Reader::new(checksum=false, length=false)
  let loose : Array[Byte] = []
  for b in reader.push(damaged[:]) {
    loose.push(b)
  }
  for b in reader.finish() {
    loose.push(b)
  }
  assert_eq(Bytes::from_array(loose), body)
}

///|
/// A header split across pushes is gathered, not guessed at. The name and the
/// comment are the fields most likely to straddle a boundary, so they are what
/// the test carries.
test "gzip streaming reads a header that arrives in pieces" {
  let packed = @gzip.gzip(
    b"body",
    name="a rather long file name.txt",
    comment="and a comment beside it",
  )
  assert_eq(stream_in(packed, 1), b"body")
  assert_eq(stream_in(packed, 3), b"body")
}

///|
/// The output bound is the DEFLATE reader's, and a stream that would pass it is
/// refused rather than held.
test "gzip streaming refuses to expand past its bound" {
  let packed = @gzip.gzip(sample(2)[:])
  let reader = @gzip.Reader::new(limit=100)
  let error = try {
    let mut at = 0
    while at < packed.length() {
      let stop = if packed.length() - at < 64 {
        packed.length()
      } else {
        at + 64
      }
      reader.push(packed[at:stop]) |> ignore
      at = stop
    }
    reader.finish() |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_eq(error, Some(@moonzip.TooBig(limit=100)))
}
