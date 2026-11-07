// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The standard library's flate is the other reference we hold ourselves to:
/// the format is RFC 1951, and a decoder that reads our streams and a writer
/// whose streams its decoder reads is the interop that the one-shot pair and
/// the streaming pair each claim. This is the half that the Python vectors in
/// the other tests cannot cover, because it is a second implementation of the
/// same format written against the same specification, and the two agreeing is
/// what "both are right" means.
///
/// The bodies are the same seven shapes the conformance vectors are taken over
/// (the `body_of` this package's tests already build), so a shape that is a
/// problem shows up in both at once.

///|
/// What the standard library's writer writes, read by this one, over every body
/// shape: a stream the other side produced, decoded to the body it started from.
test "the standard library's deflate streams decode to the body" {
  for kind in 0..<7 {
    let body = body_of(kind)
    let packed = @flate.deflate_all(body[:])
    assert_eq(@deflate.inflate(packed[:]), body)
  }
}

///|
/// What this one writes, in the default parse, read by the standard library: the
/// same body back, through a decoder we do not own.
test "our deflate streams decode in the standard library" {
  for kind in 0..<7 {
    let body = body_of(kind)
    let packed = @deflate.deflate(body[:])
    assert_eq(@flate.inflate_exact(packed[:]), body)
  }
}

///|
/// The long-match parse writes a stream the standard library decodes too: a
/// different parse, the same format, and the interop holds for it as well.
test "the long-match streams decode in the standard library" {
  for kind in 0..<7 {
    let body = body_of(kind)
    let packed = @deflate.deflate(body[:], strategy=LongMatch)
    assert_eq(@flate.inflate_exact(packed[:]), body)
  }
}

///|
/// The standard library's writer can take a strategy, and the one it names other
/// than the standard walk still decodes here: the `Optimal` parse, which is the
/// same family of search this package runs under the name `LongMatch`.
test "the standard library's optimal streams decode to the body" {
  for kind in 0..<7 {
    let body = body_of(kind)
    let packed = @flate.deflate_all(
      body[:],
      strategy=@flate.Strategy::optimal(),
    )
    assert_eq(@deflate.inflate(packed[:]), body)
  }
}
