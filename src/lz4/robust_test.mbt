// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A body with something for the match finder and something that defeats it: a
/// long run, real text, and a tail of noise.
fn probe_body() -> Bytes {
  let out : Array[Byte] = []
  for _ in 0..<300 {
    out.push(b'a')
  }
  for i in 0..<200 {
    for b in "the quick brown fox jumps over the lazy dog. " {
      out.push((b.to_int() % 256).to_byte())
    }
    out.push((i % 251).to_byte())
  }
  let mut state : UInt32 = 7U
  for _ in 0..<500 {
    state = state * 1103515245U + 12345U
    out.push(((state >> 16) & 0xFF).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// Three cuts of a valid stream, each refused rather than half decoded: one byte
/// short, half way, and a handful of bytes. The three land on a missing trailer, a
/// missing block, and a missing header, which is where a reader stops for three
/// different reasons.
test "a shortened lz4 stream is refused" {
  let packed = @lz4.frame(probe_body()[:])
  let cuts : Array[Int32] = [packed.length() - 1, packed.length() / 2, 4]
  for cut in cuts {
    let mut said_no = false
    try @lz4.unframe(packed[0:cut]) |> ignore catch {
      _ => said_no = true
    }
    assert_true(said_no)
  }
}

///|
/// The empty body is the one a frame writer gets wrong: an empty frame still needs
/// its header and its end mark, and one of them is usually left out.
test "an empty lz4 stream round-trips" {
  let packed = @lz4.frame(b""[:])
  assert_eq(@lz4.unframe(packed[:]).length(), 0)
}

///|
/// Every level that reports a size decodes to the same bytes, and the limit is the
/// caller's — enforced before the memory is spent rather than after.
test "a lz4 stream round-trips and respects the limit" {
  let body = probe_body()
  let packed = @lz4.frame(body[:])
  assert_eq(@lz4.unframe(packed[:]), body)
  let mut said_no = false
  try @lz4.unframe(packed[:], limit=body.length() - 1) |> ignore catch {
    _ => said_no = true
  }
  assert_true(said_no)
}
