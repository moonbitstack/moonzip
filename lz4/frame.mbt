// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The magic number a frame starts with.
let frame_magic : UInt32 = 0x184D2204U

///|
/// How much input one block holds. Sixty-four kilobytes is the smallest of the
/// four sizes the format allows, and the one that keeps a decoder's buffer small
/// — which is the point of a format chosen for speed.
let block_size : Int32 = 65536

///|
/// Wrap LZ4 blocks in a frame: a header, the blocks, an end mark and a content
/// checksum.
///
/// Blocks are independent, so a decoder can start at any of them; the content
/// checksum is over the original bytes rather than the compressed ones, so it
/// catches a decoder that produced the wrong thing rather than only a link that
/// flipped a bit.
///
/// A block that does not compress is stored as it is with the high bit of its
/// length set, which is how the format says "this one is verbatim".
pub fn frame(data : BytesView, level~ : Int32 = 0) -> Bytes {
  let out : Array[Byte] = []
  put32(out, frame_magic)
  // FLG: version 01, blocks independent, no block checksum, no content size in
  // the header, content checksum present, no dictionary.
  let flags = 0x64
  // BD: sixty-four-kilobyte blocks and nothing else set.
  let descriptor = 0x40
  out.push(flags.to_byte())
  out.push(descriptor.to_byte())
  let header = Bytes::from_array([flags.to_byte(), descriptor.to_byte()])
  out.push(((xxh32(header[:]) >> 8) & 0xFFU).to_byte())
  let mut at = 0
  let n = data.length()
  while at < n {
    let stop = if n - at < block_size { n } else { at + block_size }
    let chunk = data[at:stop]
    let packed = lz4(chunk, level~)
    if packed.length() < chunk.length() {
      put32(out, packed.length().reinterpret_as_uint())
      for b in packed {
        out.push(b)
      }
    } else {
      put32(out, chunk.length().reinterpret_as_uint() | 0x80000000U)
      for b in chunk {
        out.push(b)
      }
    }
    at = stop
  }
  put32(out, 0U)
  put32(out, xxh32(data))
  Bytes::from_array(out)
}

///|
/// Read a frame back.
///
/// `checksum` is what turns "some bytes came out" into "the right bytes came
/// out"; a caller recovering what it can from a damaged transfer turns it off.
/// A skippable frame — the format's way of saying "not mine, step over it" — is
/// stepped over rather than refused.
pub fn unframe(
  data : BytesView,
  checksum~ : Bool = true,
  limit? : Int32,
) -> Bytes raise @moonzip.Refused {
  let bound = match limit {
    Some(n) => n
    None => -1
  }
  let out : Array[Byte] = []
  let mut at = 0
  while at + 4 <= data.length() {
    let magic = read32(data, at)
    if (magic & 0xFFFFFFF0U) == 0x184D2A50U {
      // A skippable frame: a length and that many bytes to step over.
      if at + 8 > data.length() {
        raise @moonzip.Truncated(at~)
      }
      at += 8 + read32(data, at + 4).reinterpret_as_int()
      continue
    }
    guard magic == frame_magic else {
      raise @moonzip.Header(at~, what="not an LZ4 frame")
    }
    at += 4
    guard at + 3 <= data.length() else { raise @moonzip.Truncated(at~) }
    let flags = data[at].to_int()
    let descriptor = data[at + 1].to_int()
    if flags >> 6 != 1 {
      raise @moonzip.Header(
        at~,
        what="a frame version this reader does not know",
      )
    }
    let has_size = (flags & 0x08) != 0
    let has_block_sum = (flags & 0x10) != 0
    let has_sum = (flags & 0x04) != 0
    let has_dict = (flags & 0x01) != 0
    if has_dict {
      raise @moonzip.Header(
        at~,
        what="a preset dictionary, which is not supported",
      )
    }
    let biggest = match (descriptor >> 4) & 0x07 {
      4 => 65536
      5 => 262144
      6 => 1048576
      7 => 4194304
      _ =>
        raise @moonzip.Header(
          at~,
          what="a block size the format does not define",
        )
    }
    let _ = biggest
    let checked = ((xxh32(data[at:at + 2]) >> 8) & 0xFFU).reinterpret_as_int()
    if checked != data[at + 2].to_int() {
      raise @moonzip.Checksum(
        want=checked.reinterpret_as_uint(),
        got=data[at + 2].to_uint(),
      )
    }
    at += 3
    if has_size {
      at += 8
    }
    guard at <= data.length() else { raise @moonzip.Truncated(at~) }
    let mut ended = false
    while !ended {
      guard at + 4 <= data.length() else { raise @moonzip.Truncated(at~) }
      let header = read32(data, at)
      at += 4
      if header == 0U {
        ended = true
        break
      }
      let verbatim = (header & 0x80000000U) != 0U
      let length = (header & 0x7FFFFFFFU).reinterpret_as_int()
      guard at + length <= data.length() else { raise @moonzip.Truncated(at~) }
      let block = data[at:at + length]
      let made = if verbatim { block.to_owned() } else { unlz4(block, limit?) }
      if bound >= 0 && out.length() + made.length() > bound {
        raise @moonzip.TooBig(limit=bound)
      }
      for b in made {
        out.push(b)
      }
      at += length
      if has_block_sum {
        at += 4
      }
    }
    if has_sum {
      guard at + 4 <= data.length() else { raise @moonzip.Truncated(at~) }
      let want = read32(data, at)
      at += 4
      let got = xxh32(Bytes::from_array(out)[:])
      if checksum && want != got {
        raise @moonzip.Checksum(want~, got~)
      }
    }
  }
  Bytes::from_array(out)
}

///|
fn put32(out : Array[Byte], value : UInt32) -> Unit {
  for i in 0..<4 {
    out.push(((value >> (i * 8)) & 0xFFU).to_byte())
  }
}
