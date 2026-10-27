// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Compress and decompress a body a piece at a time.
///
///     moon run src/examples/stream
///
/// The point of the streaming interface is that neither the body nor its
/// compressed form is ever held whole: what is held is the 32 KiB window the
/// compressor needs and the four bytes of running checksum. This walks one body
/// through both halves of that — out in 4 KiB pieces, back in 777-byte pieces —
/// and checks the result against the body it started with.
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
  let source = body()
  println("body: \{source.length()} bytes")

  // Out: a gzip stream written four kilobytes at a time.
  let writer = @gzip.Writer::new(level=9)
  let packed : Array[Byte] = []
  let mut at = 0
  while at < source.length() {
    let stop = if source.length() - at < 4096 {
      source.length()
    } else {
      at + 4096
    }
    for b in writer.push(source[at:stop]) {
      packed.push(b)
    }
    at = stop
  }
  for b in writer.finish() {
    packed.push(b)
  }
  let gzipped = Bytes::from_array(packed)
  println(
    "gzip: \{gzipped.length()} bytes (\{100 - gzipped.length() * 100 / source.length()}% smaller)",
  )

  // Back: the same stream read 777 bytes at a time, which is a size that lands
  // inside headers, inside codes and inside stored blocks at least once each.
  let reader = @gzip.Reader::new()
  let out : Array[Byte] = []
  let mut at = 0
  while at < gzipped.length() {
    let stop = if gzipped.length() - at < 777 {
      gzipped.length()
    } else {
      at + 777
    }
    for b in reader.push(gzipped[at:stop]) {
      out.push(b)
    }
    at = stop
  }
  for b in reader.finish() {
    out.push(b)
  }
  let back = Bytes::from_array(out)
  println("gunzip: \{back.length()} bytes, matches: \{back == source}")

  // And the zlib container, which is what HTTP calls `deflate`.
  let writer = @zlib.Writer::new()
  let packed : Array[Byte] = []
  for b in writer.push(source[:]) {
    packed.push(b)
  }
  for b in writer.finish() {
    packed.push(b)
  }
  let zlibbed = Bytes::from_array(packed)
  let reader = @zlib.Reader::new()
  let out : Array[Byte] = []
  for b in reader.push(zlibbed[:]) {
    out.push(b)
  }
  for b in reader.finish() {
    out.push(b)
  }
  println(
    "zlib: \{zlibbed.length()} bytes, matches: \{Bytes::from_array(out) == source}",
  )

  // Raw DEFLATE streams too, with no container at all.
  let writer = @deflate.Writer::new(blocks=@deflate.Blocks::Dynamic)
  let packed : Array[Byte] = []
  for b in writer.push(source[:]) {
    packed.push(b)
  }
  for b in writer.finish() {
    packed.push(b)
  }
  let dynamic = Bytes::from_array(packed).length()
  println("raw deflate, dynamic blocks: \{dynamic} bytes")

  // The two formats chosen for speed rather than ratio, on the same body. The
  // comparison is the point of having both: lz4 and snappy give up two points of
  // ratio to decode several times faster, and which one is right depends on
  // whether the caller is storing or servicing.
  let fast = @lz4.lz4(source[:])
  println("lz4 block: \{fast.length()} bytes")
  println("lz4 frame: \{@lz4.frame(source[:]).length()} bytes")
  println("snappy block: \{@snappy.snappy(source[:]).length()} bytes")
  println("snappy frame: \{@snappy.frame(source[:]).length()} bytes")

  // The two block-sorting-ish formats: bzip2 sorts, xz range-codes. Both beat
  // DEFLATE on text and both pay for it in setup, which is the trade the table in
  // the README is about.
  println("bzip2 block: \{@bzip2.bzip2(source[:]).length()} bytes")
  println("xz: \{@xz.xz(source[:]).length()} bytes")
  println("lzma alone: \{@lzma.lzma(source[:]).length()} bytes")
  println("zstd: \{@zstd.zstd(source[:]).length()} bytes")
  println("brotli: \{@brotli.brotli(source[:]).length()} bytes")

  // And the round trips, so the numbers are of something that works.
  if @lz4.unframe(@lz4.frame(source[:])[:]) != source {
    abort("lz4 frame did not round-trip")
  }
  if @snappy.unframe(@snappy.frame(source[:])[:]) != source {
    abort("snappy frame did not round-trip")
  }
  let packed_twice = @bzip2.bzip2(source[:])
  if @bzip2.bunzip2(packed_twice[:]) != source {
    abort("bzip2 did not round-trip")
  }
  let xzed = @xz.xz(source[:])
  if @xz.unxz(xzed[:]) != source {
    abort("xz did not round-trip")
  }
  let zed = @zstd.zstd(source[:])
  if @zstd.unzstd(zed[:]) != source {
    abort("zstd did not round-trip")
  }
  let binned = @brotli.brotli(source[:])
  if @brotli.unbrotli(binned[:]) != source {
    abort("brotli did not round-trip")
  }
  println("both fast formats round-trip")
}
