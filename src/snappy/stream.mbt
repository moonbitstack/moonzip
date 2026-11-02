// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A framed writer that takes the body a piece at a time.
///
/// The framing format's unit is a sixty-four-kilobyte chunk with its own
/// checksum, so a writer can hand each one over as soon as it fills and hold
/// nothing else. That is why the format exists: a receiver reads a chunk, checks
/// it, and appends.
///
/// ```moonbit nocheck
/// let w = @snappy.Writer::new()
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
  /// The chunk being filled.
  mut held : Array[Byte]
  /// The stream identifier, handed out with the first chunk — or by `finish`
  /// when the body is empty, because a stream with no identifier is not one.
  mut header : Array[Byte]
  mut closed : Bool
}

///|
pub fn Writer::new() -> Writer {
  let header : Array[Byte] = []
  for b in identifier {
    header.push(b.to_byte())
  }
  { held: [], header, closed: false, }
}

///|
fn Writer::emit(self : Writer, made : Array[Byte]) -> Bytes {
  if self.header.length() == 0 {
    return Bytes::from_array(made)
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
fn Writer::chunk(self : Writer, out : Array[Byte]) -> Unit {
  let part = Bytes::from_array(self.held)
  self.held = []
  let packed = snappy(part[:])
  let sum = @moonzip.mask_crc32c(@moonzip.crc32c(part[:]))
  if packed.length() < part.length() {
    out.push(b'\x00')
    le24(out, packed.length() + 4)
    le32(out, sum)
    for b in packed {
      out.push(b)
    }
  } else {
    out.push(b'\x01')
    le24(out, part.length() + 4)
    le32(out, sum)
    for b in part {
      out.push(b)
    }
  }
}

///|
pub fn Writer::push(self : Writer, data : BytesView) -> Bytes {
  if self.closed {
    abort("snappy: the writer is finished")
  }
  let out : Array[Byte] = []
  let mut at = 0
  while at < data.length() {
    let room = chunk_size - self.held.length()
    let take = if data.length() - at < room { data.length() - at } else { room }
    for i in at..<(at + take) {
      self.held.push(data[i])
    }
    at += take
    if self.held.length() == chunk_size {
      self.chunk(out)
    }
  }
  self.emit(out)
}

///|
pub fn Writer::finish(self : Writer) -> Bytes {
  if self.closed {
    return b""
  }
  self.closed = true
  let out : Array[Byte] = []
  if self.held.length() > 0 {
    self.chunk(out)
  }
  self.emit(out)
}

///|
/// A framed reader that is fed a piece at a time.
///
/// A chunk is the largest thing held: its header says its length, so a reader
/// waits for exactly that many bytes and then decodes, and the memory it needs
/// is one chunk whatever the body's length.
struct Reader {
  checksum : Bool
  limit : Int32
  /// Bytes received and not yet consumed: one chunk's header and body.
  mut pending : Array[Byte]
  /// Whether the identifier has gone past — a chunk before it is not a stream.
  mut seen_identifier : Bool
  /// How much has come out of the whole stream, for `limit`.
  mut total : Int32
}

///|
pub fn Reader::new(checksum~ : Bool = true, limit? : Int32) -> Reader {
  {
    checksum,
    limit: match limit {
      Some(n) => n
      None => -1
    },
    pending: [],
    seen_identifier: false,
    total: 0,
  }
}

///|
fn Reader::drop(self : Reader, used : Int32) -> Unit {
  if used <= 0 {
    return
  }
  let rest : Array[Byte] = []
  for i in used..<self.pending.length() {
    rest.push(self.pending[i])
  }
  self.pending = rest
}

///|
pub fn Reader::push(
  self : Reader,
  data : BytesView,
) -> Bytes raise @moonzip.Refused {
  for b in data {
    self.pending.push(b)
  }
  let view = Bytes::from_array(self.pending)[:]
  let out : Array[Byte] = []
  let mut used = 0
  while used + 4 <= view.length() {
    let kind = view[used].to_int()
    let length = view[used + 1].to_int() |
      (view[used + 2].to_int() << 8) |
      (view[used + 3].to_int() << 16)
    if used + 4 + length > view.length() {
      break
    }
    let body = view[used + 4:used + 4 + length]
    let at = used
    used += 4 + length
    if kind == 0xFF {
      if length != 6 {
        raise @moonzip.Header(
          at~,
          what="a stream identifier of the wrong length",
        )
      }
      for i in 0..<6 {
        if body[i] != identifier[i + 4].to_byte() {
          raise @moonzip.Header(at~, what="not a Snappy stream")
        }
      }
      if self.seen_identifier {
        raise @moonzip.Header(at~, what="a second stream identifier")
      }
      self.seen_identifier = true
      continue
    }
    if kind == 0x00 || kind == 0x01 {
      if !self.seen_identifier {
        raise @moonzip.Header(at~, what="a chunk before the stream identifier")
      }
      if length < 4 {
        raise @moonzip.Truncated(at~)
      }
      let want = read32(body, 0)
      let made = if kind == 0x00 {
        unsnappy(body[4:])
      } else {
        body[4:].to_owned()
      }
      self.total += made.length()
      if self.limit >= 0 && self.total > self.limit {
        raise @moonzip.TooBig(limit=self.limit)
      }
      if self.checksum {
        let got = @moonzip.mask_crc32c(@moonzip.crc32c(made[:]))
        if want != got {
          raise @moonzip.Checksum(want~, got~)
        }
      }
      for b in made {
        out.push(b)
      }
      continue
    }
    // Padding, reserved and skippable: the format says a reader steps over
    // anything from 0x80 up without understanding it.
    if kind >= 0x80 {
      continue
    }
    raise @moonzip.Header(
      at~,
      what="an unskippable chunk of a type this reader does not know",
    )
  }
  self.drop(used)
  Bytes::from_array(out)
}

///|
pub fn Reader::finish(self : Reader) -> Bytes raise @moonzip.Refused {
  let tail = self.push(b"")
  if self.pending.length() > 0 {
    raise @moonzip.Truncated(at=self.pending.length())
  }
  if !self.seen_identifier {
    raise @moonzip.Header(at=0, what="not a Snappy stream")
  }
  tail
}
