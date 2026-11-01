// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One body of each shape the decoder has to survive.
///
/// The list is the same one the conformance vectors are taken over, and it is
/// repeated here because these tests are about the decoder's own paths rather
/// than about bytes anyone else produced: nothing, a byte, a run, text, noise, a
/// short cycle, and seventy kilobytes — past the 32 KiB window, where a
/// back-reference that reaches too far would land on the wrong byte.
fn body_of(kind : Int32) -> Bytes {
  let out : Array[Byte] = []
  match kind {
    0 => ()
    1 => out.push(b'a')
    2 =>
      for _ in 0..<1000 {
        out.push(b'a')
      }
    3 =>
      for i in 0..<300 {
        for b in "the quick brown fox jumps over the lazy dog. " {
          out.push((b.to_int() % 256).to_byte())
        }
        out.push((i % 251).to_byte())
      }
    4 =>
      for i in 0..<3000 {
        out.push((i * 71 % 251).to_byte())
      }
    5 =>
      for i in 0..<2000 {
        out.push((i % 4).to_byte())
      }
    _ =>
      for i in 0..<70000 {
        out.push((i % 13).to_byte())
      }
  }
  Bytes::from_array(out)
}

///|
/// Did the call refuse?
fn refused(action : () -> Unit raise) -> Bool {
  let mut said_no = false
  action() catch {
    _ => said_no = true
  }
  said_no
}

///|
/// Every block form decodes to the bytes it was given, over every body shape.
///
/// The four forms are not variations on a theme — a stored block has no Huffman
/// code at all, a fixed one uses a table that is not in the stream, and a dynamic
/// one carries its own table in a format of its own — so each is a separate path
/// through the reader, and the empty body is the one that catches a writer that
/// emits no block at all.
test "every block form round-trips every body" {
  let forms : Array[@deflate.Blocks] = [
    @deflate.Blocks::Auto,
    @deflate.Blocks::Fixed,
    @deflate.Blocks::Dynamic,
    @deflate.Blocks::Stored,
  ]
  for kind in 0..<7 {
    let body = body_of(kind)
    for form in forms {
      let packed = @deflate.deflate(body[:], blocks=form)
      assert_eq(@deflate.inflate(packed[:]), body)
    }
  }
}

///|
/// Every prefix of a valid stream is refused rather than half decoded.
///
/// A truncated stream is the shape most bad input arrives in, and the requirement
/// is not that it decodes — it is that the reader says so. A prefix can land
/// anywhere: inside a Huffman code, between two symbols, in the middle of a stored
/// payload, or on the boundary between two blocks. Each of those is a different
/// place for the sentinel to come back from.
test "every truncation of a stream is refused" {
  let body = body_of(3)
  let packed = @deflate.deflate(body[:])
  for cut in 0..<packed.length() {
    let head = packed[0:cut]
    assert_true(refused(fn() raise { @deflate.inflate(head[:]) |> ignore }))
  }
}

///|
/// A stream with bytes after its last block leaves them for the container that
/// wraps it — and hands back whole bytes that a look-ahead had already pulled.
///
/// A gzip trailer is exactly those bytes, and so is the second member of a
/// multi-member file. The look-ahead is what makes this worth a test: it reads
/// ahead by up to two bytes, so the trailer can be sitting in the accumulator
/// rather than in the buffer, and a `rest` that only looked at the buffer would
/// lose its first bytes.
test "rest hands back exactly the bytes the stream did not use" {
  let body = body_of(3)
  let packed = @deflate.deflate(body[:])
  let trailer : Array[Byte] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33]
  let joined : Array[Byte] = []
  for b in packed {
    joined.push(b)
  }
  for b in trailer {
    joined.push(b)
  }
  let reader = @deflate.Reader::new()
  let out : Array[Byte] = []
  for b in reader.push(Bytes::from_array(joined)[:]) {
    out.push(b)
  }
  for b in reader.finish() {
    out.push(b)
  }
  assert_eq(Bytes::from_array(out), body)
  assert_eq(reader.rest(), Bytes::from_array(trailer))
}

///|
/// Feeding the stream a byte at a time decodes the same bytes as feeding it at
/// once.
///
/// Every step of the decoder is finished or not started, and this is what says
/// so: a chunk boundary can fall mid-code, mid-stored-payload, or between a
/// length and its distance, and none of those may change the answer.
test "one byte at a time decodes the same bytes" {
  let body = body_of(5)
  let packed = @deflate.deflate(body[:])
  let reader = @deflate.Reader::new()
  let out : Array[Byte] = []
  for i in 0..<packed.length() {
    for b in reader.push(packed[i:i + 1]) {
      out.push(b)
    }
  }
  for b in reader.finish() {
    out.push(b)
  }
  assert_eq(Bytes::from_array(out), body)
}

///|
/// The limit bounds the output, and is checked before the memory is spent.
///
/// A compressed stream says nothing about how far it expands, so a reader taking
/// input from elsewhere has to be able to say "not more than this". The number is
/// the one the caller gave, not the one the stream would have reached.
test "the limit bounds the output" {
  let body = body_of(2)
  let packed = @deflate.deflate(body[:])
  assert_eq(@deflate.inflate(packed[:], limit=1000), body)
  assert_true(
    refused(fn() raise { @deflate.inflate(packed[:], limit=999) |> ignore }),
  )
}

///|
/// A body whose last block is stored but whose earlier blocks were compressed
/// decodes — the transition a look-ahead can break.
///
/// Incompressible bytes after compressible ones is the shape that puts a stored
/// block right after a compressed one, which is where a look-ahead that leaves
/// whole bytes in the accumulator loses the stored payload's first bytes.
test "stored after compressed decodes" {
  let out : Array[Byte] = []
  for b in body_of(3) {
    out.push(b)
  }
  let mut state : UInt32 = 12345U
  for _ in 0..<4000 {
    state = state * 1103515245U + 12345U
    out.push(((state >> 16) & 0xFF).to_byte())
  }
  let body = Bytes::from_array(out)
  assert_eq(@deflate.inflate(@deflate.deflate(body[:])[:]), body)
}

///|
/// Level changes the size and nothing else.
///
/// Every level has to decode, and a higher level has to do no worse: the search
/// only ever finds matches the shallower one could also have found, so the bytes
/// may change but the ratio may not get worse.
test "every level decodes and no level loses to a shallower one" {
  let body = body_of(3)
  let mut previous = body.length() * 2
  for level in 0..<10 {
    let packed = @deflate.deflate(body[:], level~)
    assert_eq(@deflate.inflate(packed[:]), body)
    assert_true(packed.length() <= previous)
    previous = packed.length()
  }
}
