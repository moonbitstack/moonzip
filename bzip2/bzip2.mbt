// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The six bytes that open a block, and the six that close a stream. They are
/// decimal digits of pi and of Euler's number, which is what bzip2 chose to make
/// a damaged file obvious in a hex dump.
let block_marker : FixedArray[Int32] = [0x31, 0x41, 0x59, 0x26, 0x53, 0x59]

///|
let end_marker : FixedArray[Int32] = [0x17, 0x72, 0x45, 0x38, 0x50, 0x90]

///|
/// Which of the two markers comes next, or `None` if it is neither.
fn marker(bits : Bits) -> Int32? raise @moonzip.Refused {
  let seen : Array[Int32] = []
  for _ in 0..<6 {
    seen.push(need(bits, 8))
  }
  let mut is_block = true
  let mut is_end = true
  for i in 0..<6 {
    if seen[i] != block_marker[i] {
      is_block = false
    }
    if seen[i] != end_marker[i] {
      is_end = false
    }
  }
  if is_block {
    Some(0)
  } else if is_end {
    Some(1)
  } else {
    None
  }
}

///|
/// Decompress a bzip2 stream.
///
/// `limit` is how much output the caller is prepared to hold; a compressed stream
/// says nothing about how far it expands, so a reader of untrusted input should
/// say. Past it, `TooBig` rather than an allocation.
///
/// ```moonbit nocheck
/// let plain = @bzip2.bunzip2(packed[:])
/// ```
pub fn bunzip2(
  data : BytesView,
  limit? : Int32,
) -> Bytes raise @moonzip.Refused {
  run(
    data,
    match limit {
      Some(n) => n
      None => -1
    },
  )
}

///|
/// The one-shot reader, with the bound passed down rather than in an option.
fn run(data : BytesView, limit : Int32) -> Bytes raise @moonzip.Refused {
  let bits = Bits::new(data)
  match read_up_to(bits, limit) {
    Some(out) => out
    None => raise @moonzip.Truncated(at=bits.used())
  }
}

///|
/// Everything the stream holds, or `None` if the bytes run out first.
///
/// Both entry points go through here: the one-shot reader turns `None` into
/// `Truncated`, and a reader being fed a piece at a time keeps the position and
/// asks again when it has more.
fn read_up_to(bits : Bits, limit : Int32) -> Bytes? raise @moonzip.Refused {
  Some(decode_all(bits, limit)) catch {
    @moonzip.Truncated(_) => None
    error => raise error
  }
}

///|
fn decode_all(bits : Bits, limit : Int32) -> Bytes raise @moonzip.Refused {
  for i in 0..<3 {
    let want = [0x42, 0x5A, 0x68][i]
    if need(bits, 8) != want {
      raise @moonzip.Header(at=0, what="this is not a bzip2 stream")
    }
  }
  let level_byte = need(bits, 8)
  if level_byte < 0x31 || level_byte > 0x39 {
    raise @moonzip.Header(
      at=3,
      what="a block size that is not a digit from one to nine",
    )
  }
  let level = level_byte - 0x30
  let out : Array[Byte] = []
  let mut combined = 0U
  let mut done = false
  while !done {
    let what = match marker(bits) {
      Some(kind) => kind
      None =>
        raise @moonzip.Header(
          at=bits.used() - 6,
          what="a block marker that is neither the block nor the end of stream",
        )
    }
    if what == 1 {
      let want = match bits.take_word() {
        Some(v) => v
        None => raise @moonzip.Truncated(at=bits.used())
      }
      if want != combined {
        raise @moonzip.Checksum(want~, got=combined)
      }
      done = true
      continue
    }
    let (block, stamp) = read_block(bits, level)
    if limit >= 0 && out.length() + block.length() > limit {
      raise @moonzip.TooBig(limit~)
    }
    // The combined checksum is each block's own, rotated one bit and xored in, so
    // a block that is out of order or missing shows up at the end as well as at
    // its own trailer.
    combined = ((combined << 1) | (combined >> 31)) ^ stamp
    for byte in block {
      out.push(byte)
    }
  }
  Bytes::from_array(out)
}
