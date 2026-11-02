// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A frame writer that takes the body a piece at a time.
///
/// A frame is a sequence of independent blocks, so the unit of work is one
/// block: what is held between calls is the sixty-four kilobytes being filled and
/// the running content checksum, never the body. A push that does not fill a
/// block produces nothing, which is the format's own granularity rather than a
/// choice made here.
///
/// ```moonbit nocheck
/// let w = @lz4.Writer::new(level=0)
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
  level : Int32
  /// The block being filled.
  mut held : Array[Byte]
  sum : Xxh32
  /// The header, handed out with the first chunk that produces any output.
  mut header : Array[Byte]
  mut closed : Bool
}

///|
pub fn Writer::new(level~ : Int32 = 0) -> Writer {
  let out : Array[Byte] = []
  put32(out, frame_magic)
  // FLG: version 01, blocks independent, no block checksum, no content size in
  // the header, content checksum present, no dictionary.
  let flags = 0x64
  // BD: sixty-four-kilobyte blocks and nothing else set.
  let descriptor = 0x40
  out.push(flags.to_byte())
  out.push(descriptor.to_byte())
  let head = Bytes::from_array([flags.to_byte(), descriptor.to_byte()])
  out.push(((xxh32(head[:]) >> 8) & 0xFFU).to_byte())
  { level, held: [], sum: Xxh32::new(), header: out, closed: false, }
}

///|
/// Put the header in front of the first non-empty output, so a body that fits in
/// one block comes back as one array rather than two.
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
/// Take one whole block: compressed when that is smaller, verbatim otherwise.
fn Writer::block(self : Writer, out : Array[Byte], part : BytesView) -> Unit {
  let packed = lz4(part, level=self.level)
  if packed.length() < part.length() {
    put32(out, packed.length().reinterpret_as_uint())
    for b in packed {
      out.push(b)
    }
  } else {
    put32(out, part.length().reinterpret_as_uint() | 0x80000000U)
    for b in part {
      out.push(b)
    }
  }
}

///|
pub fn Writer::push(self : Writer, data : BytesView) -> Bytes {
  if self.closed {
    abort("lz4: the writer is finished")
  }
  self.sum.push(data)
  let out : Array[Byte] = []
  let mut at = 0
  while at < data.length() {
    let room = block_size - self.held.length()
    let take = if data.length() - at < room { data.length() - at } else { room }
    for i in at..<(at + take) {
      self.held.push(data[i])
    }
    at += take
    if self.held.length() == block_size {
      let part = Bytes::from_array(self.held)
      self.block(out, part[:])
      self.held = []
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
  // An empty body is a frame with no blocks at all, which is why the last one is
  // written only when something is in it.
  if self.held.length() > 0 {
    let part = Bytes::from_array(self.held)
    self.block(out, part[:])
    self.held = []
  }
  put32(out, 0U)
  put32(out, self.sum.finish())
  self.emit(out)
}

///|
/// A frame reader that is fed a piece at a time.
///
/// The unit is again one block: the reader holds the bytes of the block it is
/// waiting for and decodes it the moment it is complete, so the memory it needs
/// is the frame's declared block size whatever the body's length. A block that
/// arrives in pieces produces nothing until it is whole, and one that arrives
/// whole is handed back by the same push.
struct Reader {
  checksum : Bool
  limit : Int32
  /// Bytes received and not yet consumed: a part of the header, or one block.
  mut pending : Array[Byte]
  /// The largest a block may be, from the descriptor: 64 KiB to 4 MiB.
  mut biggest : Int32
  /// Whether the frame being read carries a content checksum, which is in the
  /// flags byte at the front and needed again at the end mark.
  mut content_sum : Bool
  mut sum : Xxh32
  /// How much has come out of the whole stream, for `limit`.
  mut total : Int32
  /// Zero at a frame header, one at a block header, three at a frame's content
  /// checksum.
  mut stage : Int32
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
    biggest: 65536,
    content_sum: true,
    sum: Xxh32::new(),
    total: 0,
    stage: 0,
  }
}

///|
/// Drop the bytes that have been consumed.
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
  while true {
    let left = view.length() - used
    if self.stage == 0 {
      if left < 4 {
        break
      }
      let magic = read32(view, used)
      if (magic & 0xFFFFFFF0U) == 0x184D2A50U {
        // A skippable frame: a length and that many bytes to step over. It is
        // part of the stream and carries nothing this reader decodes.
        if left < 8 {
          break
        }
        let size = read32(view, used + 4).reinterpret_as_int()
        if left < 8 + size {
          break
        }
        used += 8 + size
        continue
      }
      if magic != frame_magic {
        raise @moonzip.Header(at=used, what="not an LZ4 frame")
      }
      if left < 7 {
        break
      }
      let flags = view[used + 4].to_int()
      let descriptor = view[used + 5].to_int()
      if flags >> 6 != 1 {
        raise @moonzip.Header(
          at=used,
          what="a frame version this reader does not know",
        )
      }
      if (flags & 0x01) != 0 {
        raise @moonzip.Header(
          at=used,
          what="a preset dictionary, which is not supported",
        )
      }
      let head = Bytes::from_array([view[used + 4], view[used + 5]])
      let want = ((xxh32(head[:]) >> 8) & 0xFFU).reinterpret_as_int()
      if want != view[used + 6].to_int() {
        raise @moonzip.Checksum(
          want=want.reinterpret_as_uint(),
          got=view[used + 6].to_uint(),
        )
      }
      self.biggest = match (descriptor >> 4) & 0x07 {
        4 => 65536
        5 => 262144
        6 => 1048576
        7 => 4194304
        _ =>
          raise @moonzip.Header(
            at=used,
            what="a block size the format does not define",
          )
      }
      self.content_sum = (flags & 0x04) != 0
      // The optional content size rides between the descriptor and the blocks and
      // is only a promise about the body, so it is stepped over.
      let skip = if (flags & 0x08) != 0 { 8 } else { 0 }
      if left < 7 + skip {
        break
      }
      used += 7 + skip
      self.stage = 1
      continue
    }
    if self.stage == 1 {
      if left < 4 {
        break
      }
      let head = read32(view, used)
      used += 4
      if head == 0U {
        // The end mark. A frame that says nothing about its checksum is over
        // here, and another may follow it.
        if self.content_sum {
          self.stage = 3
        } else {
          self.sum = Xxh32::new()
          self.stage = 0
        }
        continue
      }
      let verbatim = (head & 0x80000000U) != 0U
      let length = (head & 0x7FFFFFFFU).reinterpret_as_int()
      if length > self.biggest {
        raise @moonzip.Header(
          at=used - 4,
          what="a block larger than the descriptor allows",
        )
      }
      if left < 4 + length {
        used -= 4
        break
      }
      let block = view[used:used + length]
      let made = if verbatim { block.to_owned() } else { unlz4(block) }
      self.total += made.length()
      if self.limit >= 0 && self.total > self.limit {
        raise @moonzip.TooBig(limit=self.limit)
      }
      self.sum.push(made[:])
      for b in made {
        out.push(b)
      }
      used += length
      continue
    }
    if self.stage == 3 {
      if left < 4 {
        break
      }
      let want = read32(view, used)
      used += 4
      let got = self.sum.finish()
      if self.checksum && want != got {
        raise @moonzip.Checksum(want~, got~)
      }
      self.sum = Xxh32::new()
      self.stage = 0
      continue
    }
    break
  }
  self.drop(used)
  Bytes::from_array(out)
}

///|
pub fn Reader::finish(self : Reader) -> Bytes raise @moonzip.Refused {
  let tail = self.push(b"")
  if self.stage != 0 || self.pending.length() > 0 {
    raise @moonzip.Truncated(at=self.pending.length())
  }
  tail
}
