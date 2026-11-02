// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A body of each shape worth testing: nothing, one byte, a run, text with a
/// periodic tail, noise, and something big enough to cross a meta-block.
fn sample(kind : Int32) -> Bytes {
  let out : Array[Byte] = []
  if kind == 0 {
    return Bytes::from_array(out)
  }
  if kind == 1 {
    out.push(b'a')
    return Bytes::from_array(out)
  }
  if kind == 2 {
    for _ in 0..<5000 {
      out.push(b'z')
    }
    return Bytes::from_array(out)
  }
  if kind == 3 {
    for i in 0..<200 {
      for c in "the quick brown fox jumps over the lazy dog. " {
        out.push((c.to_int() % 256).to_byte())
      }
      out.push((i % 251).to_byte())
    }
    return Bytes::from_array(out)
  }
  if kind == 4 {
    let mut x = 12345U
    for _ in 0..<8192 {
      x = x * 1103515245U + 12345U
      out.push(((x >> 16) & 0xFFU).reinterpret_as_int().to_byte())
    }
    return Bytes::from_array(out)
  }
  for i in 0..<200000 {
    out.push((65 + i % 17).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// Everything we write, we can read.
test "round trip, every shape" {
  for kind in 0..<6 {
    let body = sample(kind)
    let packed = @brotli.brotli(body)
    let back = @brotli.unbrotli(packed)
    if back != body {
      fail(
        "shape \{kind}: \{body.length()} bytes in, \{packed.length()} out, \{back.length()} back",
      )
    }
  }
}

///|
/// The writer is plain, but plain still has to compress: a body of English text
/// with a repeated line should come out well under half its size. Noise is
/// allowed to expand — it does in every compressor.
test "text compresses" {
  let body = sample(3)
  let packed = @brotli.brotli(body)
  if packed.length() * 2 >= body.length() {
    fail("\{body.length()} bytes of text only reached \{packed.length()}")
  }
}

///|
/// The window size is a parameter, and every legal one has to produce a stream
/// we can read back — including the smallest, where almost nothing is reachable.
test "round trip, every window size" {
  let body = sample(3)
  for window in [10, 16, 17, 18, 24] {
    let packed = @brotli.brotli(body, window~)
    let back = @brotli.unbrotli(packed)
    if back != body {
      fail(
        "window \{window}: \{back.length()} bytes back, not \{body.length()}",
      )
    }
  }
}

///|
/// The reader has to survive input nobody would write: it must refuse, not hang
/// and not read out of bounds.
test "truncated streams are refused" {
  let body = sample(3)
  let packed = @brotli.brotli(body)
  let mut refused = 0
  for cut in [1, 2, 3, 5, 9, 17] {
    if cut < packed.length() {
      let part = packed[:cut]
      try {
        let _ = @brotli.unbrotli(part)
      } catch {
        _ => refused += 1
      }
    }
  }
  if refused < 6 {
    fail("only \{refused} of six truncations were refused")
  }
}

///|
/// An empty stream is legal and produces nothing.
test "empty input" {
  let packed = @brotli.brotli(Bytes::new(0))
  let back = @brotli.unbrotli(packed)
  if back.length() != 0 {
    fail("\{back.length()} bytes out of an empty stream")
  }
}

///|
/// A bound the caller set is honoured rather than quietly exceeded.
test "the output bound is enforced" {
  let packed = @brotli.brotli(sample(2))
  try {
    let _ = @brotli.unbrotli(packed, limit=100)
    fail("a 5000-byte body came back through a 100-byte bound")
  } catch {
    @moonzip.TooBig(_) => ()
    e => fail("wrong refusal: \{e}")
  }
}

///|
/// The large-window extension is a different, deliberately incompatible format.
/// A stream that asks for it is refused by name rather than decoded as if the
/// header were RFC 7932 — the difference is a window size the rest of the stream
/// silently disagrees with.
test "the large-window extension is refused" {
  // Window bits: one, then three zeros, then a one, which is the escape that only
  // large-window brotli may use.
  let stream : Bytes = b"\x11\x00\x00"
  try {
    let _ = @brotli.unbrotli(stream[:])
    fail("a large-window header was accepted")
  } catch {
    e => if !(e is @moonzip.Header(_)) { fail("wrong refusal: \{e}") }
  }
}

///|
/// Bytes that are not a brotli stream at all must come back as a refusal, not as
/// a crash and not as output. Every one of these starts with a bit pattern that
/// is legal somewhere in the format, so the failure is deep in a tree rather than
/// at the door.
test "garbage is refused" {
  let text = "the quick brown fox jumps over the lazy dog"
  let body : Array[Byte] = []
  for c in text {
    body.push((c.to_int() % 256).to_byte())
  }
  let noise = @brotli.brotli(Bytes::from_array(body)[:])
  let mut refused = 0
  for at in 0..<noise.length() {
    for mask in [0x01, 0x80, 0xFF] {
      let flipped = FixedArray::make(noise.length(), b'\x00')
      for i in 0..<noise.length() {
        flipped[i] = noise[i]
      }
      flipped[at] = (flipped[at].to_int() ^ mask).to_byte()
      try {
        let _ = @brotli.unbrotli(Bytes::from_array(flipped)[:])
      } catch {
        _ => refused += 1
      }
    }
  }
  // Brotli carries no checksum, so a flipped bit may legitimately decode to
  // different bytes. What it may not do is hang or read out of bounds; if any of
  // these three hundred flips had done that, the test would not have reached the
  // line above.
  if refused == 0 {
    fail("no corruption of \{noise.length()} bytes was detected at all")
  }
}

///|
/// Every quality round-trips, and the deeper search never loses on a body with
/// long-range repeats: quality 11 must not be larger than quality 0, whatever it
/// costs in time in between.
test "quality trades ratio for time without breaking the stream" {
  let parts : Array[Byte] = []
  for i in 0..<400 {
    for b in b"the quick brown fox jumps over the lazy dog. " {
      parts.push(b)
    }
    parts.push((0x30 + i % 17).to_byte())
  }
  let data = Bytes::from_array(parts)
  for q in 0..<12 {
    let packed = @brotli.brotli(data[:], quality=q)
    assert_eq(@brotli.unbrotli(packed[:]), data)
  }
  let fast = @brotli.brotli(data[:], quality=0).length()
  let best = @brotli.brotli(data[:], quality=11).length()
  assert_true(best <= fast)
}

///|
/// The optimal parse has to earn what it costs. On a body of prose, quality 11
/// chooses its parse where quality 9 takes the longest match it finds, so eleven
/// must come out smaller — and both must read back, because the search is free to
/// emit commands the greedy pass never produces: implicit distances, insert runs
/// of lengths it would not have chosen, copies that start mid-word.
test "the optimal parse beats the greedy one" {
  let body = sample(3)
  let nine = @brotli.brotli(body[:], quality=9)
  let eleven = @brotli.brotli(body[:], quality=11)
  if @brotli.unbrotli(eleven[:]) != body {
    fail("quality 11 wrote a stream that does not read back")
  }
  if eleven.length() >= nine.length() {
    fail(
      "quality 11 wrote \{eleven.length()} bytes against quality 9's \{nine.length()}",
    )
  }
}

///|
/// The default quality is nine, so a call that names no quality produces exactly
/// what `quality=9` produces — the bytes earlier versions wrote.
test "the default quality is nine" {
  let data = b"the quick brown fox jumps over the lazy dog, again and again and again."
  assert_eq(@brotli.brotli(data[:]), @brotli.brotli(data[:], quality=9))
}
