// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A body compressed by a writer fed `step` bytes at a time.
fn stream_out(data : Bytes, step : Int32, level : Int32) -> Bytes {
  let writer = @bzip2.Writer::new(level~)
  let out : Array[Byte] = []
  let mut at = 0
  while at < data.length() {
    let stop = if data.length() - at < step { data.length() } else { at + step }
    for b in writer.push(data[at:stop]) {
      out.push(b)
    }
    at = stop
  }
  for b in writer.finish() {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// A stream read back by a reader fed `step` bytes at a time.
fn stream_in(packed : Bytes, step : Int32) -> Bytes raise @moonzip.Refused {
  let reader = @bzip2.Reader::new()
  let out : Array[Byte] = []
  let mut at = 0
  while at < packed.length() {
    let stop = if packed.length() - at < step {
      packed.length()
    } else {
      at + step
    }
    for b in reader.push(packed[at:stop]) {
      out.push(b)
    }
    at = stop
  }
  for b in reader.finish() {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// A writer fed in pieces writes the same bytes as the one-shot function.
///
/// It is not merely a valid stream: the block splits are the format's, and they
/// land in the same place however the caller sliced its body.
test "bzip2 streaming writes what the one-shot writes" {
  for kind in [1, 2, 3, 4] {
    let data = body(kind)
    for step in [1, 3, 64, 4096, 70000] {
      assert_eq(stream_out(data, step, 9), @bzip2.bzip2(data[:]))
      assert_eq(stream_out(data, step, 1), @bzip2.bzip2(data[:], level=1))
    }
  }
}

///|
/// And a reader fed in pieces gives the body back, including when the pieces are
/// smaller than a single block and the reader has to wait.
test "bzip2 streaming reads back" {
  for kind in [1, 2, 3, 4] {
    let data = body(kind)
    let packed = @bzip2.bzip2(data[:])
    for step in [1, 5, 999, 65536] {
      assert_eq(stream_in(packed, step), data)
    }
  }
}

///|
/// Three blocks, written and read a piece at a time — the combined checksum only
/// has something to combine when there is more than one block.
test "bzip2 streaming spans blocks" {
  let data = body(5)
  let packed = stream_out(data, 7777, 1)
  assert_eq(packed, @bzip2.bzip2(data[:], level=1))
  assert_eq(stream_in(packed, 4093), data)
}

///|
/// A trailer that disagrees with the body is caught, and a reader told not to
/// check still gets the bytes.
test "bzip2 streaming checks the trailer" {
  let data = body(3)
  let packed = @bzip2.bzip2(data[:])
  let spoiled : Array[Byte] = []
  for i in 0..<packed.length() {
    spoiled.push(
      if i == packed.length() - 2 {
        (packed[i].to_int() ^ 0xFF).to_byte()
      } else {
        packed[i]
      },
    )
  }
  let damaged = Bytes::from_array(spoiled)
  let error = try {
    stream_in(damaged, 64) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_true(error is Some(_))
  let reader = @bzip2.Reader::new(checksum=false)
  let out : Array[Byte] = []
  for b in reader.push(damaged[:]) {
    out.push(b)
  }
  for b in reader.finish() {
    out.push(b)
  }
  assert_eq(Bytes::from_array(out), data)
}

///|
/// A reader that has not seen the end marker says so rather than pretending the
/// stream ended.
test "bzip2 streaming finish refuses a half stream" {
  let packed = @bzip2.bzip2(body(3)[:])
  let reader = @bzip2.Reader::new()
  reader.push(packed[:packed.length() - 20]) |> ignore
  let error = try {
    reader.finish() |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_true(error is Some(_))
}
