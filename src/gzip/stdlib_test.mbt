// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The standard library's gzip is the other reference this container holds
/// itself to: RFC 1952 is the format, and a reader that decodes the other
/// side's stream and a writer whose stream the other side decodes is the
/// interop the one-shot pair claims. The bodies are the same seven shapes the
/// conformance vectors use (the `sample` this package's tests already build).

///|
/// What the standard library's writer writes, read by this one, over every body
/// shape: a stream the other side produced, decoded to the body it started
/// from, the CRC-32 and the length checked on the way back.
test "the standard library's gzip streams read back" {
  for kind in 0..<7 {
    let body = sample(kind)
    let packed = @sgzip.compress(body[:])
    assert_eq(@gzip.gunzip(packed[:]), body)
  }
}

///|
/// What this one writes, read by the standard library: the same body back,
/// through a decoder we do not own.
test "our gzip streams read in the standard library" {
  for kind in 0..<7 {
    let body = sample(kind)
    let packed = @gzip.gzip(body[:])
    assert_eq(@sgzip.decompress(packed[:]), body)
  }
}

///|
/// The long-match parse reaches the container: a gzip made with it is the
/// container around a different parse, and the standard library's reader does
/// not know the difference, because the format is the format.
test "the long-match gzip streams read in the standard library" {
  for kind in 0..<7 {
    let body = sample(kind)
    let packed = @gzip.gzip(body[:], strategy=@deflate.Strategy::LongMatch)
    assert_eq(@sgzip.decompress(packed[:]), body)
  }
}
