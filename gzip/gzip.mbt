// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Wrap DEFLATE output in a gzip container.
///
/// The modification time goes out as zero and the name is left off, so the same
/// input always gives the same bytes. A compressor that stamped the clock would
/// make a build unreproducible and a cache entry never match.
pub fn gzip(data : BytesView, level? : Int = 0) -> Bytes {
  let out : Array[Byte] = [
    b'\x1F',
    b'\x8B', // magic
    b'\x08', // CM: DEFLATE, the only method there is
    b'\x00', // FLG: no name, no comment, no extra field
    b'\x00',
    b'\x00',
    b'\x00',
    b'\x00', // MTIME: none, so the output is reproducible
    level.to_byte(), // XFL
    b'\xFF', // OS: unknown, which is the honest answer for a library
  ]
  for b in @deflate.deflate(data) {
    out.push(b)
  }
  le32(out, crc32(data))
  le32(out, data.length().reinterpret_as_uint())
  Bytes::from_array(out)
}

///|
/// Read a gzip container and decompress what is in it.
///
/// The trailing CRC-32 and length are checked, because a container that carries
/// a checksum and does not look at it is not a container.
pub fn gunzip(data : BytesView) -> Bytes raise @moonzip.Broken {
  if data.length() < 18 {
    raise @moonzip.Truncated(at=data.length())
  }
  if data[0] != b'\x1F' || data[1] != b'\x8B' {
    raise @moonzip.Header(at=0, what="not a gzip stream")
  }
  if data[2] != b'\x08' {
    raise @moonzip.Header(
      at=2,
      what="a compression method gzip does not define",
    )
  }
  let flags = data[3].to_int()
  if (flags & 0xE0) != 0 {
    raise @moonzip.Header(at=3, what="a reserved flag is set")
  }
  let mut at = 10
  if (flags & 0x04) != 0 {
    // FEXTRA: a length and that many bytes.
    if at + 2 > data.length() {
      raise @moonzip.Truncated(at~)
    }
    let len = data[at].to_int() | (data[at + 1].to_int() << 8)
    at += 2 + len
  }
  if (flags & 0x08) != 0 {
    at = past_string(data, at)
  }
  if (flags & 0x10) != 0 {
    at = past_string(data, at)
  }
  if (flags & 0x02) != 0 {
    // FHCRC: two bytes over the header, which nothing writes and nothing
    // checks, so it is skipped rather than verified.
    at += 2
  }
  if at + 8 > data.length() {
    raise @moonzip.Truncated(at~)
  }
  let end = data.length() - 8
  let body = @deflate.inflate(data[at:end])
  let want_crc = read32(data, end)
  let got_crc = crc32(body[:])
  if want_crc != got_crc {
    raise @moonzip.Checksum(want=want_crc, got=got_crc)
  }
  let want_len = read32(data, end + 4)
  // The length is written modulo 2^32, so that is how it is compared.
  if want_len != (body.length().reinterpret_as_uint() & 0xFFFFFFFF) {
    raise @moonzip.Length(want=want_len, got=body.length())
  }
  body
}

///|
/// CRC-32 as gzip and PNG use it (RFC 1952 §8): the reflected form of the
/// IEEE 802.3 polynomial, starting and ending complemented.
pub fn crc32(data : BytesView) -> UInt {
  let mut crc = 0xFFFFFFFFU
  for b in data {
    crc = crc ^ b.to_uint()
    for _ in 0..<8 {
      crc = if (crc & 1U) != 0U { (crc >> 1) ^ 0xEDB88320U } else { crc >> 1 }
    }
  }
  crc ^ 0xFFFFFFFFU
}

///|
fn le32(out : Array[Byte], value : UInt) -> Unit {
  for i in 0..<4 {
    out.push(((value >> (i * 8)) & 0xFFU).to_byte())
  }
}

///|
fn read32(data : BytesView, at : Int) -> UInt {
  let mut value = 0U
  for i in 0..<4 {
    value = value | (data[at + i].to_uint() << (i * 8))
  }
  value
}

///|
/// Step past a NUL-terminated header string.
fn past_string(data : BytesView, from : Int) -> Int raise @moonzip.Broken {
  let mut at = from
  while at < data.length() && data[at] != b'\x00' {
    at += 1
  }
  if at >= data.length() {
    raise @moonzip.Truncated(at~)
  }
  at + 1
}
