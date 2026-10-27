// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A body of each shape worth testing: empty, one byte, a long run, text with a
/// periodic tail, noise, and something past one block.
fn body(kind : Int32) -> Bytes {
  let out : Array[Byte] = []
  match kind {
    0 => ()
    1 => out.push(b'a')
    2 =>
      for _ in 0..<1000 {
        out.push(b'a')
      }
    3 =>
      for i in 0..<500 {
        for b in "the quick brown fox jumps over the lazy dog. " {
          out.push((b.to_int() % 256).to_byte())
        }
        out.push((i % 251).to_byte())
      }
    4 => {
      // A linear congruential generator: no structure for LZ77 to find, which
      // is what makes the stored form the right answer here.
      let mut x = 12345U
      for _ in 0..<4096 {
        x = x * 1103515245U + 12345U
        out.push(((x >> 16) & 0xFFU).to_byte())
      }
    }
    5 =>
      for i in 0..<40000 {
        out.push((i % 7).to_byte())
      }
    _ => ()
  }
  Bytes::from_array(out)
}

///|
/// One zlib stream, fed to a reader in chunks of `step` bytes.
fn read_in(data : Bytes, step : Int32) -> Bytes raise @moonzip.Refused {
  let reader = @zlib.Reader::new()
  let out : Array[Byte] = []
  let mut at = 0
  while at < data.length() {
    let stop = if data.length() - at < step { data.length() } else { at + step }
    for b in reader.push(data[at:stop]) {
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
/// And one writer, fed in the same chunks.
fn write_in(data : Bytes, step : Int32, level : Int32) -> Bytes {
  let writer = @zlib.Writer::new(level~)
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
/// A zlib body that arrives in any chunk size decompresses to what went in —
/// including the two header bytes, which a one-byte-at-a-time feed has to keep
/// until there are two of them.
test "zlib streams a body in any chunk size" {
  for kind in 0..<6 {
    let data = body(kind)
    let packed = @zlib.zlib(data[:])
    for step in [1, 2, 3, 5, 7, 13, 64, 511, 4096, 65536] {
      assert_eq(read_in(packed, step), data)
    }
  }
}

///|
/// The streaming writer writes what the one-shot function writes, for a body
/// that fits in one block.
test "zlib streaming writes what the one-shot writes" {
  for kind in 0..<5 {
    let data = body(kind)
    for level in [0, 1, 6, 9] {
      let whole = @zlib.zlib(data[:], level~)
      for step in [1, 4, 17, 1024, 65536] {
        assert_eq(write_in(data, step, level), whole)
      }
    }
  }
}

///|
/// The window the header names is read out of it, because a reader that has to
/// hold a window of its own needs to know how big it has to be.
test "zlib streaming reports the window its header named" {
  let packed = @zlib.zlib(b"x", window=1024)
  assert_eq(@zlib.Reader::new().window(), 32768)
  let reader = @zlib.Reader::new()
  reader.push(packed[:]) |> ignore
  assert_eq(reader.window(), 1024)
}

///|
/// A checksum that does not match is refused, and refusing it does not stop a
/// caller from asking for the bytes with the check turned off.
test "zlib streaming checks the adler it was given" {
  let data = body(3)
  let packed = @zlib.zlib(data[:])
  let spoiled : Array[Byte] = []
  for i in 0..<packed.length() {
    spoiled.push(
      if i == packed.length() - 1 {
        (packed[i].to_int() ^ 0x01).to_byte()
      } else {
        packed[i]
      },
    )
  }
  let damaged = Bytes::from_array(spoiled)
  let reader = @zlib.Reader::new()
  let error = try {
    reader.push(damaged[:]) |> ignore
    reader.finish() |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_true(error is Some(_))
  let reader = @zlib.Reader::new(checksum=false)
  let loose : Array[Byte] = []
  for b in reader.push(damaged[:]) {
    loose.push(b)
  }
  for b in reader.finish() {
    loose.push(b)
  }
  assert_eq(Bytes::from_array(loose), data)
}

///|
/// A header that claims a different compression method, or whose check bits do
/// not add up, is a header, not a stream — and a streaming reader says so as
/// soon as the two bytes are in hand.
test "zlib streaming refuses a header it cannot read" {
  let bad : Array[Byte] = [b'\x09', b'\x00']
  let reader = @zlib.Reader::new()
  let error = try {
    reader.push(Bytes::from_array(bad)[:]) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_true(error is Some(_))
}
