// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Wrap DEFLATE output in a gzip container.
///
/// The modification time is zero and the name is absent unless asked for, so
/// the same input gives the same bytes. A compressor that stamped the clock
/// would make a build unreproducible and a cache entry never match — which is
/// why Go's `gzip.Writer` also writes zero unless told otherwise. Set `mtime`
/// when the output is a file that should carry one.
///
/// `level`, `window` and `chain` go straight through to the compressor.
pub fn gzip(
  data : BytesView,
  level? : Int = 6,
  window? : Int = 32768,
  chain? : Int,
  mtime? : UInt = 0,
  name? : String,
  comment? : String,
  os? : Int = 255,
) -> Bytes {
  let mut flags = 0
  if name is Some(_) {
    flags = flags | 0x08
  }
  if comment is Some(_) {
    flags = flags | 0x10
  }
  let out : Array[Byte] = [b'\x1F', b'\x8B', b'\x08', flags.to_byte()]
  le32(out, mtime)
  out.push(xfl(level).to_byte())
  out.push((os & 0xFF).to_byte())
  match name {
    Some(text) => latin1(out, text)
    None => ()
  }
  match comment {
    Some(text) => latin1(out, text)
    None => ()
  }
  for b in @deflate.deflate(data, level~, window~, chain?) {
    out.push(b)
  }
  le32(out, crc32(data))
  le32(out, data.length().reinterpret_as_uint())
  Bytes::from_array(out)
}

///|
/// The informational compression byte: 2 when the encoder searched hardest,
/// 4 when it barely searched, 0 otherwise (RFC 1952 §2.3.1).
fn xfl(level : Int) -> Int {
  if level >= 9 {
    2
  } else if level <= 1 {
    4
  } else {
    0
  }
}

///|
/// A NUL-terminated header string. gzip header strings are ISO-8859-1, so
/// anything above U+00FF cannot be written and is refused rather than mangled.
fn latin1(out : Array[Byte], text : String) -> Unit {
  for i in 0..<text.length() {
    let c = text.at(i).to_int()
    guard c <= 0xFF else {
      abort("gzip: a header string must be ISO-8859-1, and U+\{c} is not")
    }
    out.push(c.to_byte())
  }
  out.push(b'\x00')
}

///|
/// Read a gzip container and decompress what is in it.
///
/// The trailing CRC-32 and length are checked, because a container that carries
/// a checksum and does not look at it is not a container. Each check is a
/// parameter for the cases where a stream is known to be truncated and the part
/// that arrived is still wanted.
///
/// `limit` bounds the output, for a stream that came from elsewhere.
pub fn gunzip(
  data : BytesView,
  checksum? : Bool = true,
  length? : Bool = true,
  header_crc? : Bool = true,
  limit? : Int,
) -> Bytes raise @moonzip.Broken {
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
    // FHCRC: the low sixteen bits of the CRC-32 over everything before it.
    if at + 2 > data.length() {
      raise @moonzip.Truncated(at~)
    }
    if header_crc {
      let want = (data[at].to_uint() | (data[at + 1].to_uint() << 8)) & 0xFFFFU
      let got = crc32(data[0:at]) & 0xFFFFU
      if want != got {
        raise @moonzip.Checksum(want~, got~)
      }
    }
    at += 2
  }
  if at + 8 > data.length() {
    raise @moonzip.Truncated(at~)
  }
  let end = data.length() - 8
  let body = @deflate.inflate(data[at:end], limit?)
  if checksum {
    let want_crc = read32(data, end)
    let got_crc = crc32(body[:])
    if want_crc != got_crc {
      raise @moonzip.Checksum(want=want_crc, got=got_crc)
    }
  }
  if length {
    let want_len = read32(data, end + 4)
    // The length is written modulo 2^32, so that is how it is compared.
    if want_len != (body.length().reinterpret_as_uint() & 0xFFFFFFFF) {
      raise @moonzip.Length(want=want_len, got=body.length())
    }
  }
  body
}

///|
/// CRC-32, where the container that specifies it names it.
///
/// The implementation is `@moonzip.crc32`: `zip` writes the same checksum, and
/// neither container should have to import the other to reach it.
pub fn crc32(data : BytesView) -> UInt {
  @moonzip.crc32(data)
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
