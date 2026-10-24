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
    4 =>
      for i in 0..<1200000 {
        out.push((i % 7).to_byte())
      }
    _ => ()
  }
  Bytes::from_array(out)
}

///|
test "an xz stream round-trips" {
  for kind in 0..<5 {
    let data = sample(kind)
    let packed = @xz.xz(data[:])
    println("kind \{kind}: \{data.length()} -> \{packed.length()}")
    assert_eq(@xz.unxz(packed[:]), data)
  }
}

///|
test "an xz stream with a crc32 check round-trips" {
  let data = sample(3)
  assert_eq(@xz.unxz(@xz.xz(data[:], check=@xz.Check::Crc32)[:]), data)
}
