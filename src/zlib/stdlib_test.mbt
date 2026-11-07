// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The standard library's zlib is the other reference this container holds
/// itself to: RFC 1950 is the format, and a reader that decodes the other
/// side's stream and a writer whose stream the other side decodes is the
/// interop the one-shot pair claims. The bodies are the same shapes the
/// streaming tests use (the `body` this package's tests already build), so a
/// shape that is a problem shows up in both at once.

///|
/// What the standard library's writer writes, read by this one, over every body
/// shape: a stream the other side produced, decoded to the body it started
/// from, the Adler-32 checked on the way back.
test "the standard library's zlib streams read back" {
  for kind in 0..<6 {
    let b = body(kind)
    let packed = @szlib.compress(b[:])
    assert_eq(@zlib.unzlib(packed[:]), b)
  }
}

///|
/// What this one writes, read by the standard library: the same body back,
/// through a decoder we do not own.
test "our zlib streams read in the standard library" {
  for kind in 0..<6 {
    let b = body(kind)
    let packed = @zlib.zlib(b[:])
    assert_eq(@szlib.decompress(packed[:]), b)
  }
}

///|
/// The long-match parse reaches the container: a zlib made with it is the
/// container around a different parse, and the standard library's reader decodes
/// it, because the header, the stream and the Adler-32 are the format's.
test "the long-match zlib streams read in the standard library" {
  for kind in 0..<6 {
    let b = body(kind)
    let packed = @zlib.zlib(b[:], strategy=@deflate.Strategy::LongMatch)
    assert_eq(@szlib.decompress(packed[:]), b)
  }
}
