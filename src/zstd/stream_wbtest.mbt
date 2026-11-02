// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The reader keeps the frame's window and one block: a back-reference reaches no
/// further than the window, so the bytes past it can never be asked for again.
/// Two hundred kilobytes arriving a byte at a time is where a reader that
/// gathered the stream would be holding all of it.
test "the reader's buffer is one block and its window" {
  let body : Array[Byte] = []
  for i in 0..<200000 {
    body.push((i % 7).to_byte())
  }
  let writer = Writer::new()
  let packed = writer.push(Bytes::from_array(body)[:]) + writer.finish()
  let reader = Reader::new()
  let mut biggest = 0
  for i in 0..<packed.length() {
    reader.push(packed[i:i + 1]) |> ignore
    if reader.pending.length() > biggest {
      biggest = reader.pending.length()
    }
  }
  reader.finish() |> ignore
  assert_true(biggest <= 65540)
  assert_true(reader.frame.out.length() <= 65536)
}
