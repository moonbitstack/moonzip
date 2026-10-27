// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A body of each shape worth testing: nothing, one byte, a long run, text with a
/// periodic tail, noise, and something past one block.
fn body(kind : Int32) -> Bytes {
  let out : Array[Byte] = []
  match kind {
    0 => ()
    1 => out.push(b'a')
    2 =>
      for _ in 0..<1000 {
        out.push(b'a')
      }
    3 =>
      for i in 0..<500 {
        for b in "the quick brown fox jumps over the lazy dog. " {
          out.push((b.to_int() % 256).to_byte())
        }
        out.push((i % 251).to_byte())
      }
    4 => {
      let mut x = 12345U
      for _ in 0..<4096 {
        x = x * 1103515245U + 12345U
        out.push(((x >> 16) & 0xFFU).to_byte())
      }
    }
    5 =>
      for i in 0..<200000 {
        out.push((i % 7).to_byte())
      }
    _ => ()
  }
  Bytes::from_array(out)
}

///|
/// Every shape comes back through the block format, at every search depth.
test "an lz4 block round-trips" {
  for kind in 0..<6 {
    let data = body(kind)
    for level in [0, 1, 4, 9] {
      let packed = @lz4.lz4(data[:], level~)
      assert_eq(@lz4.unlz4(packed[:]), data)
    }
  }
}

///|
/// A block that cannot be compressed is not made bigger on purpose: the format
/// allows a literal-only block, and that is what this is.
test "an lz4 block of noise is all literals" {
  let noise = body(4)
  let packed = @lz4.lz4(noise[:])
  // Twelve bytes of framing for the last-literal sequence, which is as close to
  // "nothing was gained" as a block format gets.
  assert_true(packed.length() <= noise.length() + noise.length() / 255 + 16)
  assert_eq(@lz4.unlz4(packed[:]), noise)
}

///|
/// A frame round-trips, and its content checksum is xxHash-32 of the original.
test "an lz4 frame round-trips" {
  for kind in 0..<6 {
    let data = body(kind)
    let packed = @lz4.frame(data[:])
    assert_eq(@lz4.unframe(packed[:]), data)
    // The last four bytes are the content hash.
    let want = @lz4.xxh32(data[:])
    let mut got = 0U
    for i in 0..<4 {
      got = got | (packed[packed.length() - 4 + i].to_uint() << (i * 8))
    }
    assert_eq(got, want)
  }
}

///|
/// xxHash-32 against the values published with the algorithm: the empty input and
/// the one-byte input, which are the two that catch a wrong rotation or a wrong
/// prime.
test "xxhash32 matches its published values" {
  assert_eq(@lz4.xxh32(b""[:]), 0x02CC5D05U)
  assert_eq(@lz4.xxh32(b"a"[:]), 0x550D7456U)
  assert_eq(@lz4.xxh32(b"abc"[:]), 0x32D153FFU)
}

///|
/// A frame whose content changed under it is caught, and a caller that says it
/// does not care still gets the bytes.
test "an lz4 frame catches a damaged body" {
  let data = body(3)
  let packed = @lz4.frame(data[:])
  let last = packed.length() - 1
  let spoiled : Array[Byte] = []
  for i in 0..<packed.length() {
    spoiled.push(
      if i == last {
        (packed[i].to_int() ^ 0x01).to_byte()
      } else {
        packed[i]
      },
    )
  }
  let damaged = Bytes::from_array(spoiled)
  let error = try {
    @lz4.unframe(damaged[:]) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_true(error is Some(_))
  assert_eq(@lz4.unframe(damaged[:], checksum=false), data)
}

///|
/// The bound is what stands between a small block and a large allocation.
test "an lz4 block past the bound is refused" {
  let packed = @lz4.lz4(body(5)[:])
  let error = try {
    @lz4.unlz4(packed[:], limit=1000) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_eq(error, Some(@moonzip.TooBig(limit=1000)))
}
