// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A body of each shape worth testing.
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
      for i in 0..<140000 {
        out.push((i % 7).to_byte())
      }
    _ => ()
  }
  Bytes::from_array(out)
}

///|
/// Every shape comes back through the block format, including one that needs more
/// than sixty-four kilobytes of copies.
test "a snappy block round-trips" {
  for kind in 0..<6 {
    let data = body(kind)
    let packed = @snappy.snappy(data[:])
    assert_eq(@snappy.unsnappy(packed[:]), data)
  }
}

///|
/// Every shape comes back through the framing format, which adds the stream
/// identifier and a CRC per chunk.
test "a snappy frame round-trips" {
  for kind in 0..<6 {
    let data = body(kind)
    let packed = @snappy.frame(data[:])
    assert_eq(packed[0].to_int(), 0xFF)
    assert_eq(@snappy.unframe(packed[:]), data)
  }
}

///|
/// CRC-32C against the values published with it: the empty input, `123456789` and
/// `abc`, which are the three from the specification's own test vectors.
test "crc32c matches its published values" {
  assert_eq(@moonzip.crc32c(b""[:]), 0U)
  assert_eq(@moonzip.crc32c(b"123456789"[:]), 0xE3069283U)
  assert_eq(@moonzip.crc32c(b"abc"[:]), 0x364B3FB7U)
}

///|
/// The mask is reversible, which is what lets a reader check a chunk it has just
/// decompressed against the four bytes in front of it.
test "the crc mask is reversible" {
  let sum = @moonzip.crc32c(b"the quick brown fox"[:])
  let masked = @moonzip.mask_crc32c(sum)
  assert_true(masked != sum)
  // Unmasking is the same rotation and the same subtraction, backwards.
  let back = ((masked - 0xA282EAD8U) >> 17) | ((masked - 0xA282EAD8U) << 15)
  assert_eq(back, sum)
}

///|
/// A chunk whose bytes changed is caught by its checksum, and a caller that says
/// it does not care still gets the data.
test "a snappy frame catches a damaged chunk" {
  let data = body(3)
  let packed = @snappy.frame(data[:])
  let spoiled : Array[Byte] = []
  for i in 0..<packed.length() {
    spoiled.push(
      if i == 40 {
        (packed[i].to_int() ^ 0x10).to_byte()
      } else {
        packed[i]
      },
    )
  }
  let damaged = Bytes::from_array(spoiled)
  let error = try {
    @snappy.unframe(damaged[:]) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_true(error is Some(_))
  // Without the checksum it decompresses to something, and possibly the right
  // thing: the bit may have landed in a literal.
  let loose = @snappy.unframe(damaged[:], checksum=false)
  assert_eq(loose.length(), data.length())
}

///|
/// The length a block claims is a claim. A block that claims more than it holds is
/// a truncated block, not a shorter one.
test "a short snappy block is refused" {
  let packed = @snappy.snappy(body(2)[:])
  let error = try {
    @snappy.unsnappy(packed[:packed.length() - 5]) |> ignore
    None
  } catch {
    _ => Some(true)
  }
  assert_true(error is Some(_))
}

///|
/// And a chunk that claims a gigabyte is refused before it is allocated.
test "a snappy block past the bound is refused" {
  let packed = @snappy.snappy(body(5)[:])
  let error = try {
    @snappy.unsnappy(packed[:], limit=1000) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_eq(error, Some(@moonzip.TooBig(limit=1000)))
}
