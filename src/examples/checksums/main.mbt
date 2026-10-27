// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The three checksums the formats specify, one-shot and streamed a piece at a
/// time, plus the CRC-32C mask Snappy puts on a frame. A streaming checksum
/// reaches the same value as the one-shot because that is what "streaming" means
/// for a checksum: the same folding, just not all at once.
///
///     moon run src/examples/checksums
fn body() -> Bytes {
  let out : Array[Byte] = []
  for i in 0..<4000 {
    for b in "the quick brown fox jumps over the lazy dog. " {
      out.push((b.to_int() % 256).to_byte())
    }
    out.push((i % 251).to_byte())
  }
  Bytes::from_array(out)
}

///|
fn main {
  let b = body()
  let crc = @moonzip.crc32(b[:])
  let adler = @moonzip.adler32(b[:])
  let c32c = @moonzip.crc32c(b[:])
  println("crc32     -> \{crc}")
  println("adler32   -> \{adler}")
  println("crc32c    -> \{c32c}")
  println("masked    -> \{@moonzip.mask_crc32c(c32c)}")

  // The same three, taken four kilobytes at a time.
  let c = @moonzip.Crc::new()
  let a = @moonzip.Adler::new()
  let k = @moonzip.Castagnoli::new()
  let mut at = 0
  while at < b.length() {
    let stop = if b.length() - at < 4096 { b.length() } else { at + 4096 }
    c.push(b[at:stop])
    a.push(b[at:stop])
    k.push(b[at:stop])
    at = stop
  }
  println(
    "crc32   streamed -> \{c.finish()}  \{if c.finish() == crc { "== one-shot" } else { "DIFFERS" }}",
  )
  println(
    "adler   streamed -> \{a.finish()}  \{if a.finish() == adler { "== one-shot" } else { "DIFFERS" }}",
  )
  println(
    "crc32c  streamed -> \{k.finish()}  \{if k.finish() == c32c { "== one-shot" } else { "DIFFERS" }}",
  )
}
