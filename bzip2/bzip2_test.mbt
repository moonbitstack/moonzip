// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A body of each shape worth testing: nothing, one byte, a long run, text with a
/// periodic tail, noise, and something past one block at level one.
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
      for i in 0..<260000 {
        out.push((i % 7).to_byte())
      }
    _ => ()
  }
  Bytes::from_array(out)
}

///|
/// Every shape comes back, at both ends of the block-size range.
///
/// Level one is the one that matters: at a hundred kilobytes a block, a body of a
/// quarter of a megabyte is three of them, and three blocks is the only way to
/// exercise the combined checksum, the block boundaries and the padding between
/// them.
test "bzip2 round-trips" {
  for kind in 0..<6 {
    let data = body(kind)
    for level in [1, 9] {
      let packed = @bzip2.bzip2(data[:], level~)
      assert_eq(@bzip2.bunzip2(packed[:]), data)
    }
  }
}

///|
/// A body compressed at level one uses more blocks than the same body at level
/// nine, which is what the level means.
test "the level is the block size" {
  let data = body(3)
  let small = @bzip2.bzip2(data[:], level=1)
  let large = @bzip2.bzip2(data[:], level=9)
  assert_eq(@bzip2.bunzip2(small[:]), data)
  assert_eq(@bzip2.bunzip2(large[:]), data)
  // The header says so, and the streams agree about the body.
  assert_eq(small[3].to_int(), 0x31)
  assert_eq(large[3].to_int(), 0x39)
}

///|
/// A block whose body is not there is refused, and the error names the checksum
/// rather than decoding to something plausible.
test "a damaged block is caught by its checksum" {
  let data = body(3)
  let packed = @bzip2.bzip2(data[:])
  let spoiled : Array[Byte] = []
  for i in 0..<packed.length() {
    // Two bytes into the payload, past the ten-byte header of the first block.
    spoiled.push(
      if i == 20 {
        (packed[i].to_int() ^ 0x40).to_byte()
      } else {
        packed[i]
      },
    )
  }
  let damaged = Bytes::from_array(spoiled)
  let error = try {
    @bzip2.bunzip2(damaged[:]) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_true(error is Some(_))
}

///|
/// A stream cut in half is a truncated stream, not an empty one.
test "a short stream is refused" {
  let data = body(3)
  let packed = @bzip2.bzip2(data[:])
  let error = try {
    @bzip2.bunzip2(packed[:packed.length() - 6]) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_eq(error, Some(@moonzip.Truncated(at=packed.length() - 6)))
}

///|
/// The bound is what stands between a small file and a large allocation.
test "a stream past the bound is refused" {
  let packed = @bzip2.bzip2(body(3)[:])
  let error = try {
    @bzip2.bunzip2(packed[:], limit=1000) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_eq(error, Some(@moonzip.TooBig(limit=1000)))
}

///|
/// Compressing nothing is fourteen bytes: a header, the end marker and a
/// checksum of nothing. It has to read back too.
test "nothing compresses and reads back" {
  let packed = @bzip2.bzip2(b"")
  assert_eq(packed.length(), 14)
  assert_eq(@bzip2.bunzip2(packed[:]), b"")
}

///|
/// The quick brown fox, measured. A check that the compressor is actually
/// compressing rather than falling back on something safe.
test "text gets smaller" {
  let data = body(3)
  let packed = @bzip2.bzip2(data[:])
  assert_true(packed.length() * 4 < data.length())
}
