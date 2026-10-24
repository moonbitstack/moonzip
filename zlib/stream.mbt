// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A zlib writer that takes the body a piece at a time.
///
/// The two-byte header goes out with the first chunk, each chunk is compressed
/// and handed straight back, and the big-endian Adler-32 goes out when the body
/// is declared over. `zlib` is the container HTTP calls `deflate`, so this is
/// what a server compressing a response body wants beside it.
struct Writer {
  inner : @deflate.Writer
  sum : @moonzip.Adler
  mut header : Array[Byte]
  mut closed : Bool
}

///|
/// A writer whose header says what [`zlib`] would have been told.
pub fn Writer::new(
  level~ : Int32 = 6,
  window~ : Int32 = 32768,
  chain? : Int32,
  blocks~ : @deflate.Blocks = Auto,
) -> Writer {
  {
    inner: @deflate.Writer::new(level~, window~, chain?, blocks~),
    sum: @moonzip.Adler::new(),
    header: header_bytes(level, window),
    closed: false,
  }
}

///|
/// Compress a chunk and take what it produced, the header included the first
/// time anything comes out.
pub fn Writer::push(self : Writer, data : BytesView) -> Bytes {
  if self.closed {
    abort("zlib: the writer is finished")
  }
  self.sum.push(data)
  let made = self.inner.push(data)
  self.emit(made)
}

///|
/// Finish the stream: what the compressor still holds, then the checksum.
pub fn Writer::finish(self : Writer) -> Bytes {
  if self.closed {
    return b""
  }
  self.closed = true
  let out : Array[Byte] = []
  for b in self.emit(self.inner.finish()) {
    out.push(b)
  }
  // Adler-32 in zlib is big-endian, unlike every other integer in the family.
  let sum = self.sum.finish()
  for i in 0..<4 {
    out.push(((sum >> ((3 - i) * 8)) & 0xFFU).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// Put the header in front of the first non-empty output.
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
/// CMF and FLG: DEFLATE with a stated window, a stated effort, no dictionary,
/// and check bits that make the pair a multiple of 31 (RFC 1950 §2.2).
fn header_bytes(level : Int32, window : Int32) -> Array[Byte] {
  let cmf = 0x08 | ((window_bits(window) - 8) << 4)
  let rough = flevel(level) << 6
  let flg = rough + (31 - (cmf * 256 + rough) % 31) % 31
  [cmf.to_byte(), flg.to_byte()]
}

// ------------------------------------------------------------------ the reader

///|
/// Where a zlib reader is.
priv enum ReadStage {
  /// The header may still be arriving.
  Head
  /// Inside the DEFLATE body.
  Body
  /// Past the body; the checksum has been read.
  Tail
}

///|
/// A zlib reader that takes the stream a piece at a time.
///
/// Two bytes of header, then DEFLATE, then four bytes of checksum — and the
/// header can be split across two pushes, which is why the reader keeps them
/// rather than assuming a chunk is at least that long.
struct Reader {
  inner : @deflate.Reader
  mut stage : ReadStage
  mut head : Array[Byte]
  sum : @moonzip.Adler
  mut closed : Bool
  checksum : Bool
  /// The window the header claims, in bytes. DEFLATE cannot use more than the
  /// stream says it may, so a reader that holds the whole output need not care
  /// — but a caller reading a header in isolation does.
  mut window : Int32
}

///|
/// A reader with the same checks [`unzlib`] offers.
pub fn Reader::new(checksum~ : Bool = true, limit? : Int32) -> Reader {
  {
    inner: @deflate.Reader::new(limit?),
    stage: Head,
    head: [],
    sum: @moonzip.Adler::new(),
    closed: false,
    checksum,
    window: 32768,
  }
}

///|
/// The window the stream's header declared, in bytes.
pub fn Reader::window(self : Reader) -> Int32 {
  self.window
}

///|
/// Feed a chunk of the stream, take the bytes it decompressed to.
pub fn Reader::push(
  self : Reader,
  data : BytesView,
) -> Bytes raise @moonzip.Refused {
  if self.closed {
    abort("zlib: the reader is finished")
  }
  match self.stage {
    Head => {
      for b in data {
        self.head.push(b)
      }
      if self.head.length() < 2 {
        return b""
      }
      self.read_header()
      let at = self.head.length()
      if at <= 2 {
        return b""
      }
      let body = slice(self.head, 2, at)
      self.head = []
      self.stage = Body
      let made = self.inner.push(body[:])
      self.absorb(made)
      made
    }
    Body => {
      let made = self.inner.push(data)
      self.absorb(made)
      made
    }
    Tail => b""
  }
}

///|
/// Say the stream is complete: check the checksum, or say why it cannot be.
pub fn Reader::finish(self : Reader) -> Bytes raise @moonzip.Refused {
  if self.closed {
    abort("zlib: the reader is finished")
  }
  self.closed = true
  if self.stage is Head {
    if self.head.length() < 7 {
      raise @moonzip.Truncated(at=self.head.length())
    }
    self.read_header()
    if self.head.length() > 2 {
      let made = self.inner.push(slice(self.head, 2, self.head.length())[:])
      self.absorb(made)
    }
    self.head = []
    self.stage = Body
  }
  let made = self.inner.finish()
  self.absorb(made)
  self.stage = Tail
  let end = self.inner.rest()
  if end.length() < 4 {
    raise @moonzip.Truncated(at=0)
  }
  if self.checksum {
    let mut want = 0U
    for i in 0..<4 {
      want = (want << 8) | end[i].to_uint()
    }
    let got = self.sum.finish()
    if want != got {
      raise @moonzip.Checksum(want~, got~)
    }
  }
  made
}

///|
/// Check the two header bytes in `head` and remember the window they name.
fn Reader::read_header(self : Reader) -> Unit raise @moonzip.Refused {
  let cmf = self.head[0].to_int()
  let flg = self.head[1].to_int()
  if (cmf & 0x0F) != 8 {
    raise @moonzip.Header(
      at=0,
      what="a compression method zlib does not define",
    )
  }
  if (cmf * 256 + flg) % 31 != 0 {
    raise @moonzip.Header(at=0, what="the header check bits do not add up")
  }
  if (flg & 0x20) != 0 {
    raise @moonzip.Header(
      at=1,
      what="a preset dictionary, which is not supported",
    )
  }
  self.window = 1 << (((cmf >> 4) & 0x0F) + 8)
}

///|
/// Fold what came out into the running Adler-32.
fn Reader::absorb(self : Reader, made : Bytes) -> Unit {
  self.sum.push(made[:])
}

///|
/// A copy of `from` up to `to` as a byte string.
fn slice(a : Array[Byte], from : Int32, to : Int32) -> Bytes {
  let out : Array[Byte] = []
  for i in from..<to {
    out.push(a[i])
  }
  Bytes::from_array(out)
}
