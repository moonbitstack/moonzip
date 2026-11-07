// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A body with something for each block kind to do: a run, real text, and a tail
/// that compresses badly.
fn robust_body() -> Bytes {
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
/// Cutting a zlib stream anywhere loses the Adler-32 it ends with, and the reader
/// says so instead of handing back a short answer.
///
/// Three cuts, because they fail in three different places: one byte short is a
/// missing trailer, half way is a missing block, and a handful of bytes is a
/// missing header.
test "a shortened zlib stream is refused" {
  let packed = @zlib.zlib(robust_body()[:])
  let cuts : Array[Int32] = [packed.length() - 1, packed.length() / 2, 4]
  for cut in cuts {
    let mut said_no = false
    try @zlib.unzlib(packed[0:cut]) |> ignore catch {
      _ => said_no = true
    }
    assert_true(said_no)
  }
}

///|
/// A flipped byte inside the payload is a checksum failure, not a wrong answer.
test "a bent zlib stream is refused" {
  let packed = @zlib.zlib(robust_body()[:])
  let bent = packed.to_array()
  bent[packed.length() / 2] = (bent[packed.length() / 2].to_int() ^ 0xFF).to_byte()
  let mut said_no = false
  try @zlib.unzlib(Bytes::from_array(bent)[:]) |> ignore catch {
    _ => said_no = true
  }
  assert_true(said_no)
}

///|
/// The limit is the caller's, and it is enforced before the memory is spent.
test "the limit bounds a zlib stream" {
  let body = robust_body()
  let packed = @zlib.zlib(body[:])
  assert_eq(@zlib.unzlib(packed[:], limit=body.length()), body)
  let mut said_no = false
  try @zlib.unzlib(packed[:], limit=body.length() - 1) |> ignore catch {
    _ => said_no = true
  }
  assert_true(said_no)
}

///|
/// The container takes the strategy the compressor does: both parses decode back
/// to the body, and the long-match one writes no more — with the Adler-32 checked
/// on the way back.
test "the zlib container takes the long-match strategy" {
  let body = robust_body()
  for strat in [@deflate.Strategy::Greedy, @deflate.Strategy::LongMatch] {
    let packed = @zlib.zlib(body[:], strategy=strat)
    assert_eq(@zlib.unzlib(packed[:]), body)
  }
  assert_true(
    @zlib.zlib(body[:], strategy=@deflate.Strategy::LongMatch).length() <=
    @zlib.zlib(body[:]).length(),
  )
}
