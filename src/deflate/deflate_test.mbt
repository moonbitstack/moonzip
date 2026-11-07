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

///|
/// Two messages on one connection, decoded by a reader that keeps its window.
///
/// The pattern `permessage-deflate` needs: each message ends with a synchronising
/// flush rather than a final block, and the second message is allowed to match
/// against the first. Nothing is finished until the last message is.
test "a message ends at a flush and the next one reaches back into it" {
  let first = @utf8.encode("the quick brown fox jumps over the lazy dog. ")
  let second = @utf8.encode("the quick brown fox jumps over the lazy dog. ")
  let writer = @deflate.Writer::new(level=6)
  let head = writer.push(first[:])
  let edge = writer.flush()
  let tail = writer.push(second[:])
  let end = writer.flush()
  // A synchronising flush ends with an empty stored block: three header bits,
  // padding to the byte boundary, then a length of zero and its complement.
  assert_eq(end[end.length() - 4:], b"\x00\x00\xff\xff")
  let reader = @deflate.Reader::new()
  assert_eq(reader.flush(head + edge), first)
  assert_eq(reader.flush(tail + end), second)
  // The last message is ended the way a stream is, so the reader is over.
  assert_eq(writer.finish().length() > 0, true)
}

///|
/// The second message of a retained context is smaller than the same body
/// compressed on its own, which is the whole point of keeping it.
test "a retained window pays for itself" {
  let body = @utf8.encode("the quick brown fox jumps over the lazy dog. ")
  let kept = @deflate.Writer::new(level=6)
  let _ = kept.push(body[:])
  let _ = kept.flush()
  let repeated = kept.push(body[:])
  let edge = kept.flush()
  let fresh = @deflate.Writer::new(level=6)
  let alone = fresh.push(body[:])
  let lone_edge = fresh.flush()
  assert_true(
    repeated.length() + edge.length() < alone.length() + lone_edge.length(),
  )
}

///|
/// A reset message stands on its own, byte for byte what a new writer produces.
test "a reset message is a stream of its own" {
  let body = @utf8.encode("the quick brown fox jumps over the lazy dog. ")
  let writer = @deflate.Writer::new(level=6)
  let _ = writer.push(body[:])
  let _ = writer.flush()
  writer.reset()
  let after = writer.push(body[:])
  let edge = writer.flush()
  let fresh = @deflate.Writer::new(level=6)
  assert_eq(after, fresh.push(body[:]))
  assert_eq(edge, fresh.flush())
  // And a reader that was reset reads it as the first message of its own stream.
  let opener = @deflate.Writer::new(level=6)
  let first = opener.push(body[:])
  let first_edge = opener.flush()
  let reader = @deflate.Reader::new()
  assert_eq(reader.flush(first + first_edge), body)
  reader.reset()
  assert_eq(reader.flush(after + edge), body)
}

///|
/// What zlib writes when it flushes a message, read by us.
///
/// The two messages were compressed by one `compressobj` at level 6 in raw
/// DEFLATE with `Z_SYNC_FLUSH` after each — `scripts/zlib_message_vectors.py`
/// prints them — so the second carries back-references into the first. That is
/// what makes it a test of the window rather than of the decoder.
test "zlib's flushed messages decode while the context is kept" {
  let head = @base16.decode(
    "ca48cdc9c957c840903a0a2519a90ab9a9c5c589e9a94076628942766a6a41b1426649b142727e5e496a45899e02000000ffff",
  )
  let tail = @base16.decode(
    "4acc4b514854284e050aa428e4e74115e626562a14a526266728242526672b64e695e403b5e92900000000ffff",
  )
  let reader = @deflate.Reader::new()
  assert_eq(
    reader.flush(head[:]),
    @utf8.encode("hello hello hello, the message that keeps its context. "),
  )
  assert_eq(
    reader.flush(tail[:]),
    @utf8.encode("and a second one that may reach back into it. "),
  )
}

///|
/// The same second message without the first is refused, which is what says the
/// window above is doing the work.
test "a message that leans on a dropped window is refused" {
  let tail = @base16.decode(
    "4acc4b514854284e050aa428e4e74115e626562a14a526266728242526672b64e695e403b5e92900000000ffff",
  )
  let reader = @deflate.Reader::new()
  assert_true(refused(fn() raise { reader.flush(tail[:]) |> ignore }))
}

///|
/// A message that stops in the middle of a symbol is not a message.
test "a truncated message is refused" {
  let whole = @base16.decode(
    "ca48cdc9c957c840903a0a2519a90ab9a9c5c589e9a94076628942766a6a41b1426649b142727e5e496a45899e02000000ffff",
  )
  for cut in [1, 2, 3, 7, 10, whole.length() - 1] {
    let reader = @deflate.Reader::new()
    let piece = whole[0:cut].to_owned()
    assert_true(refused(fn() raise { reader.flush(piece[:]) |> ignore }))
  }
}

///|
/// A message may arrive a byte at a time and still end where the flush is.
test "a message split across pushes" {
  let body = @utf8.encode(
    "a body that arrives in pieces, which is the case this exists for",
  )
  let writer = @deflate.Writer::new(level=9)
  let _ = writer.push(body[:])
  let stream = writer.flush()
  for step in [1, 2, 3, 5, 7, 13] {
    let reader = @deflate.Reader::new()
    let out : Array[Byte] = []
    let mut at = 0
    while at < stream.length() {
      let stop = if stream.length() - at < step {
        stream.length()
      } else {
        at + step
      }
      for b in reader.push(stream[at:stop]) {
        out.push(b)
      }
      at = stop
    }
    // The marker is what says the message is over; a reader that pushed every
    // byte has already decoded it, so the flush call carries nothing.
    // The last few bytes were held back by the buffer guard, so the flush is
    // what finishes the message and hands the rest over.
    for b in reader.flush(b"") {
      out.push(b)
    }
    assert_eq(Bytes::from_array(out), body)
  }
}

///|
/// A body that builds a Huffman tree deeper than the fifteen bits DEFLATE allows,
/// and so takes the length-limited path in the writer.
///
/// A word list of eight, each followed by a three-digit number: most bytes arrive
/// inside matches, so the literals that are left are a sparse, wildly uneven
/// sample of the alphabet, and the tree that comes out of it is deep. A repair
/// that loses a symbol there produces a code no decoder can follow, and nothing
/// about the sizes involved says so: the stream is short, well formed to the eye,
/// and unreadable from the first literal the lost symbol names.
fn skewed(cap : Int32) -> Bytes {
  let words = [
    "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
  ]
  let out : Array[Byte] = []
  let mut state : UInt32 = 123456789U
  while out.length() < cap {
    state = state * 1103515245U + 12345U
    let word = words[(state >> 16).reinterpret_as_int() % 8]
    for b in word {
      out.push((b.to_int() & 0xFF).to_byte())
    }
    out.push(b' ')
    let number = ((state >> 8) % 1000U).reinterpret_as_int()
    for ch in number.to_string() {
      out.push((ch.to_int() & 0xFF).to_byte())
    }
    out.push(b' ')
  }
  Bytes::from_array(out[:cap])
}

///|
/// Every level writes a stream that reads back, over a body that forces the
/// length limit.
test "a body that builds a tree deeper than the limit still round-trips" {
  for cap in [1000, 70000, 300000, 620000] {
    let body = skewed(cap)
    for level in [1, 6, 9] {
      let packed = @deflate.deflate(body[:], level~)
      assert_eq(@deflate.inflate(packed[:]), body)
    }
  }
}

///|
/// A body that repeats at more than one period: the shape where a longer match
/// at a farther distance beats the shorter one the greedy walk takes.
fn prose(cap : Int32, seed : UInt32) -> Bytes {
  let words = [
    "the", "and", "brown", "fox", "jumps", "over", "lazy", "dog", "quick", "runs",
    "then", "back", "across", "past", "slowly", "under",
  ]
  let out : Array[Byte] = []
  let mut s : UInt32 = seed
  while out.length() < cap {
    s = s * 1103515245U + 12345U
    let w = words[(s >> 16).reinterpret_as_int() % 16]
    for b in w {
      out.push((b.to_int() & 0xFF).to_byte())
    }
    out.push(b' ')
  }
  Bytes::from_array(out)
}

///|
/// The long-match strategy round-trips every body shape, the same seven the
/// greedy walk is checked on.
test "the long-match strategy round-trips every body" {
  for kind in 0..<7 {
    let body = body_of(kind)
    let packed = @deflate.deflate(body[:], strategy=LongMatch)
    assert_eq(@deflate.inflate(packed[:]), body)
  }
}

///|
/// Omitting the strategy and asking for `Greedy` are the same call: the default
/// is the parse the output has always been, so a caller who does not choose
/// gets exactly what they have always gotten.
test "the default strategy is the greedy walk" {
  let body = prose(40000, 123456U)
  assert_eq(
    @deflate.deflate(body[:]),
    @deflate.deflate(body[:], strategy=Greedy),
  )
}

///|
/// The long-match parse is among the candidates the block writer measures, so
/// it writes no more than the greedy one over every body it is given: the win
/// is on some, never a loss on any.
test "the long-match strategy never writes more than the greedy walk" {
  for kind in 0..<7 {
    let body = body_of(kind)
    let greedy = @deflate.deflate(body[:])
    let long = @deflate.deflate(body[:], strategy=LongMatch)
    assert_true(long.length() <= greedy.length())
  }
  for cap in [60000, 120000] {
    let body = prose(cap, 123456U)
    let greedy = @deflate.deflate(body[:])
    let long = @deflate.deflate(body[:], strategy=LongMatch)
    assert_true(long.length() <= greedy.length())
  }
}

///|
/// On a body that repeats at more than one period the long-match parse writes
/// fewer bytes than the greedy walk: a shorter copy that leaves a longer one a
/// few positions on is worth taking, and the greedy walk does not see it.
test "the long-match strategy saves bytes on a body with more than one period" {
  let body = prose(120000, 123456U)
  let greedy = @deflate.deflate(body[:])
  let long = @deflate.deflate(body[:], strategy=LongMatch)
  assert_true(long.length() < greedy.length())
  assert_eq(@deflate.inflate(long[:]), body)
}

///|
/// The long-match parse is deterministic: the same body, twice, is the same
/// bytes, so a build that turns the strategy on is reproducible.
test "the long-match strategy is deterministic" {
  let body = prose(60000, 4242U)
  assert_eq(
    @deflate.deflate(body[:], strategy=LongMatch),
    @deflate.deflate(body[:], strategy=LongMatch),
  )
}

///|
/// A level of zero is stored blocks whatever the strategy is: there is nothing
/// to parse, and the strategy has nothing to decide.
test "level zero stores the input under either strategy" {
  let body = body_of(3)
  assert_eq(
    @deflate.deflate(body[:], level=0),
    @deflate.deflate(body[:], level=0, strategy=LongMatch),
  )
}

///|
/// The streaming writer takes the strategy the one-shot does, and a block cut at
/// the streaming chunk boundary decodes to the bytes it was given.
test "the streaming writer round-trips a body with the long-match strategy" {
  let body = prose(90000, 999U)
  let w = @deflate.Writer::new(strategy=LongMatch)
  let out : Array[Byte] = []
  // Push in pieces smaller than a chunk, so a block boundary is not the same
  // as a push boundary.
  let mut i = 0
  while i < body.length() {
    let stop = if i + 1000 < body.length() { i + 1000 } else { body.length() }
    for b in w.push(body[i:stop]) {
      out.push(b)
    }
    i = stop
  }
  for b in w.finish() {
    out.push(b)
  }
  assert_eq(@deflate.inflate(Bytes::from_array(out)[:]), body)
}
