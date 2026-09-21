// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A body compressed three ways and read back each time.
///
///     moon run examples/tour
#coverage.skip
fn main raise {
  let out : Array[Byte] = []
  for _ in 0..<200 {
    for b in "the quick brown fox jumps over the lazy dog. " {
      out.push((b.to_int() % 256).to_byte())
    }
  }
  let body = Bytes::from_array(out)
  println("original    -> \{body.length()} bytes")
  let raw = @deflate.deflate(body[:])
  println(
    "deflate     -> \{raw.length()} bytes, back to \{@deflate.inflate(raw[:]).length()}",
  )
  let gz = @gzip.gzip(body[:])
  println(
    "gzip        -> \{gz.length()} bytes, back to \{@gzip.gunzip(gz[:]).length()}",
  )
  let zl = @zlib.zlib(body[:])
  println(
    "zlib        -> \{zl.length()} bytes, back to \{@zlib.unzlib(zl[:]).length()}",
  )
  println("crc32       -> \{@gzip.crc32(body[:])}")
  println("adler32     -> \{@zlib.adler32(body[:])}")

  // A stream that has been tampered with does not quietly decompress.
  let bent = gz.to_array()
  bent[20] = (bent[20].to_int() ^ 0xFF).to_byte()
  try @gzip.gunzip(Bytes::from_array(bent)[:]) |> ignore catch {
    Checksum(..) =>
      println("tampered    -> refused: the checksum does not match")
    _ => println("tampered    -> refused")
  } noraise {
    _ => println("tampered    -> accepted, which would be the bug")
  }
}
