// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A frame writer that takes the body a piece at a time.
///
/// A zstd frame is a run of blocks, each with its own literals and sequences, so
/// the unit of work is one block: what is held between calls is the sixty-four
/// kilobytes being filled. The frame says its window in the header instead of its
/// content size, because a writer that has not seen the body cannot promise one.
///
/// ```moonbit nocheck
/// let w = @zstd.Writer::new(level=3)
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
  /// The header, handed out with the first chunk that produces any output.
  mut header : Array[Byte]
  mut closed : Bool
}

///|
pub fn Writer::new(level~ : Int32 = 3) -> Writer {
  let out : Array[Byte] = []
  for b in magic {
    out.push(b.to_byte())
  }
  // No content size, no checksum, no dictionary: what is left is the window
  // descriptor, which is the only thing a frame without a size must state.
  out.push(0x00)
  out.push(window_descriptor(block_limit))
  { level, held: [], header: out, closed: false, }
}

///|
/// The window size, as the header's one byte: a power of two from 1 KiB, plus
/// an eighth of it in the low three bits.
fn window_descriptor(size : Int32) -> Byte {
  let mut exponent = 10
  while exponent < 41 && 1 << (exponent + 1) <= size {
    exponent += 1
  }
  let base = 1 << exponent
  let mantissa = if base >= size { 0 } else { (size - base) * 8 / base }
  (((exponent - 10) << 3) | mantissa).to_byte()
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
/// Take one whole block: its literals and sequences when that is smaller than
/// the bytes themselves, verbatim when it is not.
fn Writer::block(
  self : Writer,
  out : Array[Byte],
  part : BytesView,
  last : Bool,
) -> Unit {
  let packed = compress_block(part, self.level)
  let stored = packed.length() >= part.length()
  let body = if stored { part.to_owned() } else { packed }
  let header = (if last { 1 } else { 0 }) |
    ((if stored { 0 } else { 2 }) << 1) |
    (body.length() << 3)
  for i in 0..<3 {
    out.push(((header >> (i * 8)) & 0xFF).to_byte())
  }
  for b in body {
    out.push(b)
  }
}

///|
pub fn Writer::push(self : Writer, data : BytesView) -> Bytes {
  if self.closed {
    abort("zstd: the writer is finished")
  }
  let out : Array[Byte] = []
  let mut at = 0
  while at < data.length() {
    let room = block_limit - self.held.length()
    let take = if data.length() - at < room { data.length() - at } else { room }
    for i in at..<(at + take) {
      self.held.push(data[i])
    }
    at += take
    if self.held.length() == block_limit {
      let part = Bytes::from_array(self.held)
      self.block(out, part[:], false)
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
  // The frame ends with a block marked last, and an empty body still needs one,
  // because a frame with no block at all is not a frame.
  let part = Bytes::from_array(self.held)
  self.held = []
  self.block(out, part[:], true)
  self.emit(out)
}

///|
/// A frame reader that is fed a piece at a time.
///
/// The blocks of a frame are not independent — the repeat offsets and the four
/// entropy tables carry from one to the next — so what a reader keeps is the
/// frame's state, trimmed to its window: a back-reference reaches at most that
/// far, and the bytes past it can never be asked for again.
struct Reader {
  checksum : Bool
  limit : Int32
  /// Bytes received and not yet consumed: a part of the header, or one block.
  mut pending : Array[Byte]
  mut frame : Frame
  /// The content size the header promised, or zero when it promised none.
  mut content_size : Int64
  /// Whether the frame in progress carries a checksum, from its descriptor.
  mut frame_sum : Bool
  /// The frame's content checksum, over the bytes before the window dropped
  /// them: a checksum computed on what is left would be a checksum of the tail.
  mut sum : @moonzip.Crc
  /// How much has come out of the whole stream, for `limit`.
  mut total : Int32
  /// Zero at a frame header, one at a block header, two at a frame's checksum.
  mut stage : Int32
}

///|
pub fn Reader::new(checksum~ : Bool = true, limit? : Int32) -> Reader {
  let frame = Frame::{
    out: [],
    window: 1024,
    repeats: [1, 4, 8],
    literals_tree: None,
    ll_table: None,
    of_table: None,
    ml_table: None,
  }
  {
    checksum,
    limit: match limit {
      Some(n) => n
      None => -1
    },
    pending: [],
    frame,
    content_size: 0L,
    sum: @moonzip.Crc::new(),
    frame_sum: false,
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
/// How many bytes a frame header takes, from its descriptor. Zero means the
/// buffer does not hold enough of it yet to say.
fn header_length(descriptor : Int32) -> Int32 {
  let fcs_flag = descriptor >> 6
  let single_segment = (descriptor & 0x20) != 0
  let dict_flag = descriptor & 0x03
  let dict_size = match dict_flag {
    0 => 0
    1 => 1
    2 => 2
    _ => 4
  }
  let fcs_size = match fcs_flag {
    0 => if single_segment { 1 } else { 0 }
    1 => 2
    2 => 4
    _ => 8
  }
  1 + (if single_segment { 0 } else { 1 }) + dict_size + fcs_size
}

///|
/// Keep only what a back-reference can still reach, and only as much of that as
/// the window covers.
fn Reader::trim(self : Reader) -> Unit {
  let over = self.frame.out.length() - self.frame.window
  if over <= 0 {
    return
  }
  let kept : Array[Byte] = []
  for i in over..<self.frame.out.length() {
    kept.push(self.frame.out[i])
  }
  self.frame.out = kept
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
      let tag = read32(view, used)
      if tag >= 0x184D2A50U && tag <= 0x184D2A5FU {
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
      if tag != 0xFD2FB528U {
        raise @moonzip.Header(at=used, what="this is not a zstd frame")
      }
      if left < 5 {
        break
      }
      let descriptor = view[used + 4].to_int()
      if (descriptor & 0x08) != 0 {
        raise @moonzip.Header(
          at=used + 4,
          what="a reserved bit that must be zero",
        )
      }
      let need = header_length(descriptor)
      if left < 4 + need {
        break
      }
      let mut at = used + 5
      let single_segment = (descriptor & 0x20) != 0
      let mut window = 0
      if !single_segment {
        let byte = view[at].to_int()
        at += 1
        let exponent = byte >> 3
        let mantissa = byte & 7
        let base = 1 << (10 + exponent)
        window = base + base / 8 * mantissa
      }
      let fcs_flag = descriptor >> 6
      let fcs_size = match fcs_flag {
        0 => if single_segment { 1 } else { 0 }
        1 => 2
        2 => 4
        _ => 8
      }
      let mut size = 0L
      for i in 0..<fcs_size {
        size = size | (view[at + i].to_int().to_int64() << (i * 8))
      }
      if fcs_size == 2 {
        size = size + 256L
      }
      if single_segment {
        window = size.to_int()
      }
      self.frame = Frame::{
        out: [],
        window: if window < 1024 {
          1024
        } else {
          window
        },
        repeats: [1, 4, 8],
        literals_tree: None,
        ll_table: None,
        of_table: None,
        ml_table: None,
      }
      self.content_size = size
      self.sum = @moonzip.Crc::new()
      self.frame_sum = (descriptor & 0x04) != 0
      used += 4 + need
      self.stage = 1
      continue
    }
    if self.stage == 1 {
      if left < 3 {
        break
      }
      let header = view[used].to_int() |
        (view[used + 1].to_int() << 8) |
        (view[used + 2].to_int() << 16)
      let last = (header & 1) != 0
      let kind = (header >> 1) & 3
      let size = header >> 3
      let payload = if kind == 1 { 1 } else { size }
      if left < 3 + payload {
        break
      }
      let body = view[used + 3:used + 3 + payload]
      let mark = self.frame.out.length()
      if kind == 0 {
        for b in body {
          self.frame.out.push(b)
        }
      } else if kind == 1 {
        for _ in 0..<size {
          self.frame.out.push(body[0])
        }
      } else if kind == 2 {
        decode_block(self.frame, body)
      } else {
        raise @moonzip.Header(
          at=used,
          what="a block type the format does not define",
        )
      }
      let made : Array[Byte] = []
      for i in mark..<self.frame.out.length() {
        made.push(self.frame.out[i])
      }
      self.sum.push(Bytes::from_array(made)[:])
      for b in made {
        out.push(b)
      }
      self.total += made.length()
      if self.limit >= 0 && self.total > self.limit {
        raise @moonzip.TooBig(limit=self.limit)
      }
      self.trim()
      used += 3 + payload
      if last {
        self.stage = if self.frame_sum { 2 } else { 0 }
      }
      continue
    }
    if self.stage == 2 {
      if left < 4 {
        break
      }
      let want = read32(view, used)
      used += 4
      let got = self.sum.finish()
      if self.checksum && want != got {
        raise @moonzip.Checksum(want~, got~)
      }
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
  if self.content_size > 0L && self.total.to_int64() != self.content_size {
    raise @moonzip.Length(
      want=self.content_size.to_int().reinterpret_as_uint(),
      got=self.total,
    )
  }
  tail
}
