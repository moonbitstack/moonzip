// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The smallest program that uses the library: one format, a call each way, and
/// a check that the bytes came back.
///
///     moon run examples/minimal
fn main raise {
  let body = b"the smallest program that uses this library"
  let packed = @gzip.gzip(body[:])
  let back = @gzip.gunzip(packed[:])
  println("original  -> \{body.length()} bytes")
  println("gzip      -> \{packed.length()} bytes")
  println("roundtrip -> \{if back == body { "ok" } else { "wrong" }}")
}
