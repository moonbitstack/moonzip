// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A gzip writer that takes the body a piece at a time.
///
/// This is the shape a response compressor wants: the header goes out with the
/// first chunk, each chunk is compressed and handed straight back, and the
/// trailer is written when the body is declared over. Neither the body nor the
/// compressed form is ever held whole — only the 32 KiB window the compressor
/// needs for its back-references and the four bytes of running checksum.
///
/// ```mbt nocheck
/// let w = @gzip.Writer::new(level=9)
/// let mut out : Array[Byte] = []
/// for part in parts {
///   for b in w.push(part[:]) {
///     out.push(b)
///   }
/// }
/// for b in w.finish() {
///   out.push(b)
/// }
/// ```
struct Writer {
  inner : @deflate.Writer
  sum : @moonzip.Crc
  mut size : Int32
  /// The header, handed out with the first chunk that produces any output.
  mut header : Array[Byte]
  mut closed : Bool
}

///|
/// A writer whose header says what [`gzip`] would have been told.
pub fn Writer::new(
  level~ : Int32 = 6,
  window~ : Int32 = 32768,
  chain? : Int32,
  mtime~ : UInt32 = 0,
  name? : String,
  comment? : String,
  os~ : Int32 = 255,
  blocks~ : @deflate.Blocks = Auto,
) -> Writer {
  {
    inner: @deflate.Writer::new(level~, window~, chain?, blocks~),
    sum: @moonzip.Crc::new(),
    size: 0,
    header: header_bytes(level, mtime, name?, comment?, os),
    closed: false,
  }
}

///|
/// Compress a chunk and take the compressed bytes it produced, the header
/// included the first time anything comes out.
///
/// Nothing may come back for a while on a small body: the compressor holds
/// input until it has a block's worth, which is what makes the output small.
/// All of it comes back by [`finish`](#Writer::finish).
pub fn Writer::push(self : Writer, data : BytesView) -> Bytes {
  if self.closed {
    abort("gzip: the writer is finished")
  }
  self.sum.push(data)
  self.size += data.length()
  let made = self.inner.push(data)
  self.emit(made)
}

///|
/// Finish the stream: whatever the compressor still holds, then the trailer.
/// Nothing may be pushed afterwards.
pub fn Writer::finish(self : Writer) -> Bytes {
  if self.closed {
    return b""
  }
  self.closed = true
  let out : Array[Byte] = []
  for b in self.emit(self.inner.finish()) {
    out.push(b)
  }
  le32(out, self.sum.finish())
  le32(out, self.size.reinterpret_as_uint())
  Bytes::from_array(out)
}

///|
/// Put the header in front of the first non-empty output and hand the pieces
/// over. The header waits for output rather than going out on its own, so a
/// caller that pushes and then finishes does not get two arrays for a stream
/// whose whole body fits in one block.
fn Writer::emit(self : Writer, made : Bytes) -> Bytes {
  if self.header.length() == 0 {
    return made
  }
  let out : Array[Byte] = []
  for b in self.header {
    out.push(b)
  }
  self.header = []
  for b in made {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// The ten-byte header and the optional fields its flags announce.
fn header_bytes(
  level : Int32,
  mtime : UInt32,
  name? : String,
  comment? : String,
  os : Int32,
) -> Array[Byte] {
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
  out
}

// ------------------------------------------------------------------ the reader

///|
/// Where a gzip reader is.
priv enum ReadStage {
  /// Gathering the header, which may arrive in pieces.
  Head
  /// Inside the DEFLATE body.
  Body
  /// Past the end of the body; the trailer is in hand.
  Tail
}

///|
/// A gzip reader that takes the stream a piece at a time.
///
/// The header is gathered across pushes, because a chunk boundary can fall
/// anywhere in it, and the trailer is checked when the body ends. One member
/// only: a stream of concatenated members is what [`gunzip`] walks, since it
/// has the whole thing in hand and knows where the next member starts.
///
/// The checks are the ones [`gunzip`] offers, and each has the same default and
/// the same reason.
struct Reader {
  inner : @deflate.Reader
  mut stage : ReadStage
  /// Header bytes gathered so far.
  mut head : Array[Byte]
  sum : @moonzip.Crc
  mut size : Int32
  mut closed : Bool
  checksum : Bool
  length : Bool
  header_crc : Bool
}

///|
/// A reader with the same checks [`gunzip`] offers.
pub fn Reader::new(
  checksum~ : Bool = true,
  length~ : Bool = true,
  header_crc~ : Bool = true,
  limit? : Int32,
) -> Reader {
  {
    inner: @deflate.Reader::new(limit?),
    stage: Head,
    head: [],
    sum: @moonzip.Crc::new(),
    size: 0,
    closed: false,
    checksum,
    length,
    header_crc,
  }
}

///|
/// Feed a chunk of the stream, take the bytes it decompressed to.
pub fn Reader::push(
  self : Reader,
  data : BytesView,
) -> Bytes raise @moonzip.Refused {
  if self.closed {
    abort("gzip: the reader is finished")
  }
  match self.stage {
    Head => {
      for b in data {
        self.head.push(b)
      }
      match header_end(self.head) {
        None => {
          // A header that never ends is not a header. The bound is generous:
          // a file name, a comment and an extended field can all be long.
          if self.head.length() > 65536 {
            raise @moonzip.Header(at=0, what="the header never ends")
          }
          b""
        }
        Some(at) => {
          self.check_header_crc(at)
          let body = bytes_from(self.head, at, self.head.length())
          self.head = []
          self.stage = Body
          let made = self.inner.push(body[:])
          self.absorb(made)
          made
        }
      }
    }
    Body => {
      let made = self.inner.push(data)
      self.absorb(made)
      made
    }
    Tail =>
      // Bytes after the trailer belong to whatever comes next, and a streaming
      // reader has already said what it wanted. They are ignored rather than
      // refused, because a caller feeding a socket may get two members' worth.
      b""
  }
}

///|
/// Say the stream is complete: check the trailer, or say why it cannot be.
pub fn Reader::finish(self : Reader) -> Bytes raise @moonzip.Refused {
  if self.closed {
    abort("gzip: the reader is finished")
  }
  self.closed = true
  if self.stage is Head {
    // The body never started: whatever arrived was a header at most.
    match header_end(self.head) {
      None => raise @moonzip.Truncated(at=self.head.length())
      Some(at) => {
        self.check_header_crc(at)
        let body = bytes_from(self.head, at, self.head.length())
        self.head = []
        self.stage = Body
        let made = self.inner.push(body[:])
        self.absorb(made)
      }
    }
  }
  let made = self.inner.finish()
  self.absorb(made)
  self.stage = Tail
  let end = self.inner.rest()
  if end.length() < 8 {
    raise @moonzip.Truncated(at=self.size)
  }
  if self.checksum {
    let want = read32(end[:], 0)
    let got = self.sum.finish()
    if want != got {
      raise @moonzip.Checksum(want~, got~)
    }
  }
  if self.length {
    let want = read32(end[:], 4)
    if want != (self.size.reinterpret_as_uint() & 0xFFFFFFFFU) {
      raise @moonzip.Length(want~, got=self.size)
    }
  }
  made
}

///|
/// Check the header's own CRC if the stream carries one and the caller wants it
/// checked. `at` is where the header ends, so the two bytes before it are the
/// ones to compare against the low half of the CRC over everything before them.
fn Reader::check_header_crc(
  self : Reader,
  at : Int32,
) -> Unit raise @moonzip.Refused {
  let flags = self.head[3].to_int()
  if (flags & 0x02) != 0 && self.header_crc {
    let want = (
        self.head[at - 2].to_uint() | (self.head[at - 1].to_uint() << 8)
      ) &
      0xFFFFU
    let got = @moonzip.crc32(bytes_from(self.head, 0, at - 2)[:]) & 0xFFFFU
    if want != got {
      raise @moonzip.Checksum(want~, got~)
    }
  }
}

///|
/// Fold what came out into the running CRC and the count that the trailer's
/// length is compared against. The bound on the output is the DEFLATE reader's,
/// since it is the thing that knows how much it has produced.
fn Reader::absorb(self : Reader, made : Bytes) -> Unit {
  self.sum.push(made[:])
  self.size += made.length()
}

///|
/// Where the body starts in a gathered header, or `None` while the header is
/// still short or its optional fields have not all arrived.
fn header_end(head : Array[Byte]) -> Int32? raise @moonzip.Refused {
  if head.length() < 10 {
    return None
  }
  if head[0] != b'\x1F' || head[1] != b'\x8B' {
    raise @moonzip.Header(at=0, what="not a gzip stream")
  }
  if head[2] != b'\x08' {
    raise @moonzip.Header(
      at=2,
      what="a compression method gzip does not define",
    )
  }
  let flags = head[3].to_int()
  if (flags & 0xE0) != 0 {
    raise @moonzip.Header(at=3, what="a reserved flag is set")
  }
  let mut at = 10
  if (flags & 0x04) != 0 {
    if head.length() < at + 2 {
      return None
    }
    let len = head[at].to_int() | (head[at + 1].to_int() << 8)
    at += 2 + len
    if head.length() < at {
      return None
    }
  }
  if (flags & 0x08) != 0 {
    match string_end(head, at) {
      None => return None
      Some(next) => at = next
    }
  }
  if (flags & 0x10) != 0 {
    match string_end(head, at) {
      None => return None
      Some(next) => at = next
    }
  }
  if (flags & 0x02) != 0 {
    if head.length() < at + 2 {
      return None
    }
    at += 2
  }
  Some(at)
}

///|
/// One past a NUL-terminated header string, or `None` while it is unfinished.
fn string_end(head : Array[Byte], from : Int32) -> Int32? {
  let mut at = from
  while at < head.length() && head[at] != b'\x00' {
    at += 1
  }
  if at >= head.length() {
    None
  } else {
    Some(at + 1)
  }
}

///|
/// A copy of `from` up to `to` as a byte string. A header is a dozen bytes, so
/// the copy is not worth avoiding.
fn bytes_from(a : Array[Byte], from : Int32, to : Int32) -> Bytes {
  let out : Array[Byte] = []
  for i in from..<to {
    out.push(a[i])
  }
  Bytes::from_array(out)
}
