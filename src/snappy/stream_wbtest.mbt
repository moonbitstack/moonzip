// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The reader holds one chunk: its header states a length, so a reader waits for
/// exactly that many bytes and decodes. A reader that gathered the stream would
/// end up holding all of it, which is what the framing exists to avoid.
test "the reader's buffer is one chunk" {
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
  // Four bytes of chunk header and at most one chunk's body.
  assert_true(biggest <= 65540)
}
