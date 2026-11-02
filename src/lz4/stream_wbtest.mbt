// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The reader waits for one block and no more, so its buffer is the format's
/// block size however long the body is. Two hundred kilobytes arriving a byte at
/// a time is a case where a reader that gathered the stream would end up holding
/// all of it, and the whole point of the pair is that it does not.
test "the reader's buffer is one block" {
  let body : Array[Byte] = []
  for i in 0..<200000 {
    body.push((i % 7).to_byte())
  }
  let packed = frame(Bytes::from_array(body)[:])
  let reader = Reader::new()
  let mut biggest = 0
  for i in 0..<packed.length() {
    reader.push(packed[i:i + 1]) |> ignore
    if reader.pending.length() > biggest {
      biggest = reader.pending.length()
    }
  }
  reader.finish() |> ignore
  // A block header, the block, and nothing else.
  assert_true(biggest <= 65540)
}
