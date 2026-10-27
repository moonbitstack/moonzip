// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A body of each shape worth testing: nothing, one byte, a long run, text with a
/// periodic tail, noise, and something that spans several blocks.
fn sample(kind : Int32) -> Bytes {
  let out : Array[Byte] = []
  match kind {
    0 => ()
    1 => out.push(b'a')
    2 =>
      for _ in 0..<5000 {
        out.push(b'z')
      }
    3 =>
      for i in 0..<200 {
        for b in "the quick brown fox jumps over the lazy dog. " {
          out.push((b.to_int() % 256).to_byte())
        }
        out.push((i % 251).to_byte())
      }
    4 => {
      let mut x = 12345U
      for _ in 0..<8192 {
        x = x * 1103515245U + 12345U
        out.push(((x >> 16) & 0xFFU).to_byte())
      }
    }
    5 =>
      for i in 0..<200000 {
        out.push((65 + i % 17).to_byte())
      }
    _ => ()
  }
  Bytes::from_array(out)
}

///|
/// Every shape comes back through our own frame, at three search depths.
test "zstd round-trips" {
  for kind in 0..<6 {
    let data = sample(kind)
    for level in [1, 3, 9] {
      let packed = @zstd.zstd(data[:], level~)
      assert_eq(@zstd.unzstd(packed[:]), data)
    }
  }
}

///|
/// And it compresses: the repetitive bodies have to come out far smaller, and the
/// noisy one is allowed to come out slightly larger because it is stored.
test "the encoder compresses what can be compressed" {
  let text = sample(3)
  let packed = @zstd.zstd(text[:])
  assert_true(packed.length() * 8 < text.length())
  assert_eq(@zstd.unzstd(packed[:]), text)
  let run = sample(2)
  assert_true(@zstd.zstd(run[:]).length() < 100)
  assert_eq(@zstd.unzstd(@zstd.zstd(run[:])[:]), run)
}

///|
/// A frame that declares its size and then does not produce it is refused, which
/// is the check that catches a stream cut at a block boundary.
test "a short frame is refused" {
  let packed = @zstd.zstd(sample(3)[:])
  let error = try {
    @zstd.unzstd(packed[:packed.length() - 5]) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_true(error is Some(_))
}

///|
/// Something that is not a frame is refused by name.
test "a foreign stream is refused" {
  let error = try {
    @zstd.unzstd(b"not a zstd frame at all, not even close"[:]) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_true(error is Some(_))
}

///|
/// The bound stops a frame from expanding past what the caller agreed to hold.
test "a frame past the bound is refused" {
  let packed = @zstd.zstd(sample(5)[:])
  let error = try {
    @zstd.unzstd(packed[:], limit=1000) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_eq(error, Some(@moonzip.TooBig(limit=1000)))
}

///|
/// An empty input is a frame with one empty block, and it reads back as nothing.
test "nothing compresses and reads back" {
  let packed = @zstd.zstd(b"")
  assert_eq(@zstd.unzstd(packed[:]), b"")
}

///|
/// Concatenated frames are one stream, and a skippable frame in the middle is
/// stepped over rather than refused.
test "frames concatenate" {
  let one = @zstd.zstd(b"first "[:])
  let two = @zstd.zstd(b"second"[:])
  let joined : Array[Byte] = []
  for b in one {
    joined.push(b)
  }
  // A skippable frame: the magic that says "ignore me", a size, and that many
  // bytes of nothing in particular.
  for b in [0x50, 0x2A, 0x4D, 0x18, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00] {
    joined.push(b.to_byte())
  }
  for b in two {
    joined.push(b)
  }
  assert_eq(@zstd.unzstd(Bytes::from_array(joined)[:]), b"first second")
}
