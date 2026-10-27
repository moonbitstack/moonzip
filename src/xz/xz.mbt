// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The check an xz block carries: a checksum over the uncompressed data, after
/// the block's padding.
///
/// CRC-64 is xz's default; CRC-32 and none exist for streams that want them.
/// SHA-256 is in the format and is read here without being verified, because
/// verifying it would mean carrying a hash function this library does not have —
/// the stream still decodes, and the gap is stated rather than hidden.
pub(all) enum Check {
  None
  Crc32
  Crc64
} derive(Eq, Debug)

///|
pub extend Check with Eq::{equal, not_equal}

///|
pub extend Check with Debug::{to_repr}

///|
fn flag_of(check : Check) -> Int32 {
  match check {
    None => 0
    Crc32 => 1
    Crc64 => 4
  }
}

///|
fn size_of(check : Int32) -> Int32 {
  match check {
    0 => 0
    1..<=3 => 4
    4..<=6 => 8
    7..<=9 => 16
    10..<=12 => 32
    _ => 64
  }
}

///|
/// CRC-64 as xz uses it: the reflected ECMA-182 polynomial, starting and ending
/// complemented. Sixty-four bits because a block can be a gigabyte, and a
/// thirty-two-bit checksum over that much is a weaker claim than the format
/// wanted to make.
fn crc64(data : BytesView) -> UInt64 {
  let mut crc = 0xFFFFFFFFFFFFFFFFUL
  for i in 0..<data.length() {
    crc = crc ^ data[i].to_uint().to_uint64()
    for _ in 0..<8 {
      crc = if (crc & 1UL) != 0UL {
        (crc >> 1) ^ 0xC96C5795D7870F42UL
      } else {
        crc >> 1
      }
    }
  }
  crc ^ 0xFFFFFFFFFFFFFFFFUL
}

///|
fn check_of(data : BytesView, check : Check) -> Bytes {
  let out : Array[Byte] = []
  match check {
    None => ()
    Crc32 => {
      let sum = @moonzip.crc32(data)
      for i in 0..<4 {
        out.push(((sum >> (i * 8)) & 0xFFU).to_byte())
      }
    }
    Crc64 => {
      let mut left = crc64(data)
      for _ in 0..<8 {
        out.push((left & 0xFFUL).to_int().to_byte())
        left = left / 256UL
      }
    }
  }
  Bytes::from_array(out)
}

// ------------------------------------------------------------------- the varint

///|
/// xz's variable-length number: seven bits a byte, little-endian, high bit for
/// "another byte follows".
fn put_varint(out : Array[Byte], value : Int64) -> Unit {
  let mut left = value
  while left >= 0x80L {
    out.push(((left & 0x7FL) | 0x80L).to_int().to_byte())
    left = left / 128L
  }
  out.push(left.to_int().to_byte())
}

///|
fn get_varint(data : BytesView, at : Int32) -> (Int64, Int32)? {
  let mut value = 0L
  let mut scale = 1L
  let mut pos = at
  while pos < data.length() && scale <= 0x1000000000000000L {
    let byte = data[pos].to_int()
    pos += 1
    value = value + (byte & 0x7F).to_int64() * scale
    if (byte & 0x80) == 0 {
      return Some((value, pos))
    }
    scale = scale * 128L
  }
  None
}

// -------------------------------------------------------------------- the writer

///|
/// Compress into an xz stream.
///
/// One block holds everything; a stream of several blocks is what a parallel
/// compressor produces and a reader does not care either way. The block names
/// LZMA2 with a stated dictionary, the index follows it, and the footer closes
/// it — all three of which a reader checks before trusting a byte.
///
/// The block's data is padded to a four-byte boundary *before* its check, not
/// after: that is where the specification puts it, and a stream that pads
/// afterwards reads its own check three bytes early and is rejected by every
/// other implementation.
pub fn xz(
  data : BytesView,
  level~ : Int32 = 6,
  check~ : Check = Crc64,
) -> Bytes {
  guard level >= 0 && level <= 9 else {
    abort("xz: level \{level} is not between 0 and 9")
  }
  let out : Array[Byte] = []
  for b in [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00] {
    out.push(b.to_byte())
  }
  let flags = Bytes::from_array([b'\x00', flag_of(check).to_byte()])
  for b in flags {
    out.push(b)
  }
  for b in check_of(flags[:], Crc32) {
    out.push(b)
  }
  let mut unpadded = 0
  if data.length() > 0 {
    let dictionary = @lzma.dictionary_for(level)
    let header : Array[Byte] = [0, 0]
    put_varint(header, 0x21L)
    put_varint(header, 1L)
    header.push(@lzma.dict_code(dictionary).to_byte())
    while (header.length() + 4) % 4 != 0 {
      header.push(0)
    }
    header[0] = (header.length() / 4).to_byte()
    let bytes = Bytes::from_array(header)
    let crc = @moonzip.crc32(bytes[:])
    for b in bytes {
      out.push(b)
    }
    for i in 0..<4 {
      out.push(((crc >> (i * 8)) & 0xFFU).to_byte())
    }
    let body = @lzma.lzma2(data, dictionary, level)
    for b in body {
      out.push(b)
    }
    // Padding belongs between the data and the check.
    while out.length() % 4 != 0 {
      out.push(0)
    }
    let stamp = check_of(data, check)
    for b in stamp {
      out.push(b)
    }
    unpadded = bytes.length() + 4 + body.length() + stamp.length()
  }
  let index : Array[Byte] = [0x00]
  put_varint(index, if data.length() > 0 { 1L } else { 0L })
  if data.length() > 0 {
    put_varint(index, unpadded.to_int64())
    put_varint(index, data.length().to_int64())
  }
  while (index.length() + 4) % 4 != 0 {
    index.push(0)
  }
  let index_crc = crc_of_array(index)
  for i in 0..<4 {
    index.push(((index_crc >> (i * 8)) & 0xFFU).to_byte())
  }
  let index_size = index.length()
  for b in index {
    out.push(b)
  }
  let tail : Array[Byte] = []
  let words = index_size / 4 - 1
  for i in 0..<4 {
    tail.push(((words >> (i * 8)) & 0xFF).to_byte())
  }
  for b in flags {
    tail.push(b)
  }
  let tail_crc = crc_of_array(tail)
  for i in 0..<4 {
    out.push(((tail_crc >> (i * 8)) & 0xFFU).to_byte())
  }
  for b in tail {
    out.push(b)
  }
  out.push(b'Y')
  out.push(b'Z')
  Bytes::from_array(out)
}
// -------------------------------------------------------------------- the reader

///|
/// Read an xz stream.
///
/// The header, the block header, the index and the footer are each checked
/// against their own CRC, and the block against the check the header named. A
/// stream that disagrees with itself is refused rather than decoded into
/// something plausible.
pub fn unxz(data : BytesView, limit? : Int32) -> Bytes raise @moonzip.Refused {
  guard data.length() >= 24 else { raise @moonzip.Truncated(at=data.length()) }
  for i in 0..<6 {
    if data[i] != [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00][i].to_byte() {
      raise @moonzip.Header(at=0, what="not an xz stream")
    }
  }
  let flags = data[6].to_int() | (data[7].to_int() << 8)
  let want_header_crc = read32(data, 8)
  let header_crc = @moonzip.crc32(data[6:8])
  if header_crc != want_header_crc {
    raise @moonzip.Checksum(want=want_header_crc, got=header_crc)
  }
  // The check id is the low nibble of the *second* flags byte, which the
  // little-endian read put in the high half.
  let check = (flags >> 8) & 0x0F
  let mut at = 12
  let out : Array[Byte] = []
  while at < data.length() {
    if data[at] == b'\x00' {
      break
    }
    let header_size = (data[at].to_int() + 1) * 4
    guard at + header_size <= data.length() else {
      raise @moonzip.Truncated(at~)
    }
    let header = data[at:at + header_size]
    let want = read32(header, header_size - 4)
    let got = @moonzip.crc32(header[0:header_size - 4])
    if got != want {
      raise @moonzip.Checksum(want~, got~)
    }
    let block_flags = header[1].to_int()
    if (block_flags & 0x03) != 0 {
      raise @moonzip.Header(at~, what="a block with more than one filter")
    }
    let mut cursor = 2
    for bit in [0x40, 0x80] {
      if (block_flags & bit) != 0 {
        match get_varint(header, cursor) {
          Some(pair) => cursor = pair.1
          None => raise @moonzip.Truncated(at~)
        }
      }
    }
    let filter = match get_varint(header, cursor) {
      Some(pair) => {
        cursor = pair.1
        pair.0
      }
      None => raise @moonzip.Truncated(at~)
    }
    if filter != 0x21L {
      raise @moonzip.Header(
        at~,
        what="a filter that is not LZMA2, and no other filter is implemented",
      )
    }
    at += header_size
    let decoder = @lzma.Decoder::new(limit?)
    let made = @lzma.unlzma2(data, at, decoder)
    at = made.1
    match limit {
      Some(bound) =>
        if made.0.length() > bound {
          raise @moonzip.TooBig(limit=bound)
        }
      None => ()
    }
    let payload = made.0
    // The padding sits between the data and the check, so the check is found by
    // rounding up rather than by adding its own length.
    while at % 4 != 0 {
      at += 1
    }
    let stamp_len = size_of(check)
    guard at + stamp_len <= data.length() else { raise @moonzip.Truncated(at~) }
    if check == 1 || check == 4 {
      let got = check_of(payload[:], if check == 1 { Crc32 } else { Crc64 })
      for i in 0..<stamp_len {
        if data[at + i] != got[i] {
          raise @moonzip.Checksum(want=read32(data, at), got=read32(got, 0))
        }
      }
    }
    at += stamp_len
    for b in payload {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
fn read32(data : BytesView, at : Int32) -> UInt32 {
  data[at].to_uint() |
  (data[at + 1].to_uint() << 8) |
  (data[at + 2].to_uint() << 16) |
  (data[at + 3].to_uint() << 24)
}

///|
/// A CRC over a short array — an index or a footer, which are a dozen bytes.
fn crc_of_array(a : Array[Byte]) -> UInt32 {
  @moonzip.crc32(Bytes::from_array(a)[:])
}
