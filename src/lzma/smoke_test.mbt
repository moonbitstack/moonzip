// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn sample(kind : Int32) -> Bytes {
  let out : Array[Byte] = []
  match kind {
    0 => ()
    1 => out.push(b'a')
    2 =>
      for _ in 0..<1000 {
        out.push(b'a')
      }
    3 =>
      for i in 0..<200 {
        for b in "the quick brown fox jumps over the lazy dog. " {
          out.push((b.to_int() % 256).to_byte())
        }
        out.push((i % 251).to_byte())
      }
    _ => ()
  }
  Bytes::from_array(out)
}

///|
test "the lzma alone form round-trips" {
  for kind in 0..<4 {
    let data = sample(kind)
    let packed = @lzma.lzma(data[:])
    println("kind \{kind}: \{data.length()} -> \{packed.length()}")
    assert_eq(@lzma.unlzma(packed[:]), data)
  }
}
