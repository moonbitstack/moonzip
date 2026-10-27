// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Every codec in one place: compress the same body with each, read it back, and
/// report the size it reached and that the round trip held. The body is the same
/// repetitive English the README's speed table is measured on, so the numbers
/// are comparable across formats.
///
///     moon run src/examples/formats
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
fn main raise {
  let b = body()
  let n = b.length()
  println("original  -> \{n} bytes\n")

  let deflate_p = @deflate.deflate(b[:], level=9)
  let deflate_b = @deflate.inflate(deflate_p[:])

  let gzip_p = @gzip.gzip(b[:], level=9)
  let gzip_b = @gzip.gunzip(gzip_p[:])

  let zlib_p = @zlib.zlib(b[:], level=9)
  let zlib_b = @zlib.unzlib(zlib_p[:])

  let lz4_p = @lz4.lz4(b[:])
  let lz4_b = @lz4.unlz4(lz4_p[:])

  let snappy_p = @snappy.snappy(b[:])
  let snappy_b = @snappy.unsnappy(snappy_p[:])

  let lzma_p = @lzma.lzma(b[:])
  let lzma_b = @lzma.unlzma(lzma_p[:])

  let xz_p = @xz.xz(b[:])
  let xz_b = @xz.unxz(xz_p[:])

  let bzip2_p = @bzip2.bzip2(b[:])
  let bzip2_b = @bzip2.bunzip2(bzip2_p[:])

  let zstd_p = @zstd.zstd(b[:])
  let zstd_b = @zstd.unzstd(zstd_p[:])

  let brotli_p = @brotli.brotli(b[:])
  let brotli_b = @brotli.unbrotli(brotli_p[:])

  let rows : Array[(String, Bytes, Bytes)] = [
    ("deflate", deflate_p, deflate_b),
    ("gzip", gzip_p, gzip_b),
    ("zlib", zlib_p, zlib_b),
    ("lz4", lz4_p, lz4_b),
    ("snappy", snappy_p, snappy_b),
    ("lzma", lzma_p, lzma_b),
    ("xz", xz_p, xz_b),
    ("bzip2", bzip2_p, bzip2_b),
    ("zstd", zstd_p, zstd_b),
    ("brotli", brotli_p, brotli_b),
  ]
  println("format    bytes   of original   roundtrip")
  println("--------  ------  ------------  ---------")
  for (name, packed, back) in rows {
    let pct = packed.length() * 100 / n
    let ok = if back == b { "ok" } else { "MISMATCH" }
    println("\{name}  \{packed.length()}  \{pct}%  \{ok}")
  }
}
