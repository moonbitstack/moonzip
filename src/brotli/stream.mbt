// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A writer that takes the body a piece at a time.
///
/// A stream is a run of meta-blocks, and a meta-block is a megabyte, so the unit
/// of work is one of those: what is held between calls is that megabyte and the
/// window a copy may reach back into — the window is why a match found in one
/// meta-block can still be used in the next, which is what a periodic file needs.
///
/// ```moonbit nocheck
/// let w = @brotli.Writer::new(quality=9)
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
  quality : Int32
  window : Int32
  /// How much input one meta-block holds.
  block : Int32
  bits : BitWriter
  table : FixedArray[Int32]
  chain : FixedArray[Int32]
  /// The window's history and the bytes not yet written, `buf[0]` at `base`.
  mut buf : Array[Byte]
  mut base : Int32
  /// The next byte to write, counted from the start of the stream.
  mut at : Int32
  mut header : Array[Byte]
  mut closed : Bool
}

///|
pub fn Writer::new(window~ : Int32 = 22, quality~ : Int32 = 9) -> Writer {
  let size = if window < 10 { 10 } else if window > 24 { 24 } else { window }
  let bits = BitWriter::new()
  write_window(bits, size)
  {
    quality,
    window: size,
    block: 1 << 20,
    bits,
    table: FixedArray::make(1 << 16, -1),
    chain: FixedArray::make(chain_size(), -1),
    buf: [],
    base: 0,
    at: 0,
    header: bits.drain(),
    closed: false,
  }
}

///|
/// How far back a copy may reach, which is also how much of the buffer has to
/// survive a meta-block.
fn Writer::reach(self : Writer) -> Int32 {
  (1 << self.window) - 16
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
/// Drop the bytes a copy can no longer reach, and move the chains with them.
///
/// The positions the chains hold are buffer indices, so shifting the buffer means
/// shifting every one of them. That is a pass over the tables once a megabyte,
/// which is nothing next to the search that filled them.
fn Writer::shrink(self : Writer) -> Unit {
  let keep = self.reach()
  let from = self.at - keep
  if from <= self.base {
    return
  }
  let shift = from - self.base
  let rest : Array[Byte] = []
  for i in shift..<self.buf.length() {
    rest.push(self.buf[i])
  }
  self.buf = rest
  self.base = from
  for i in 0..<self.table.length() {
    let p = self.table[i]
    self.table[i] = if p < shift { -1 } else { p - shift }
  }
  for i in 0..<self.chain.length() {
    let p = self.chain[i]
    self.chain[i] = if p < shift { -1 } else { p - shift }
  }
}

///|
/// Take one whole meta-block out of the front of what has arrived.
fn Writer::metablock(self : Writer, span : Int32, last : Bool) -> Unit {
  let (depth, lazymatch, split, contexts, dictionary, optimal) = effort(
    self.quality,
  )
  let view = Bytes::from_array(self.buf)[:]
  write_block(
    self.bits,
    view,
    self.at - self.base,
    span,
    self.reach(),
    self.table,
    self.chain,
    depth,
    lazymatch,
    split,
    contexts,
    dictionary,
    optimal~,
  )
  let _ = last
  self.at += span
  self.shrink()
}

///|
pub fn Writer::push(self : Writer, data : BytesView) -> Bytes {
  if self.closed {
    abort("brotli: the writer is finished")
  }
  for b in data {
    self.buf.push(b)
  }
  while self.at - self.base + self.block <= self.buf.length() {
    self.metablock(self.block, false)
  }
  self.emit(self.bits.drain())
}

///|
pub fn Writer::finish(self : Writer) -> Bytes {
  if self.closed {
    return b""
  }
  self.closed = true
  let left = self.buf.length() - (self.at - self.base)
  if left > 0 {
    self.metablock(left, true)
  }
  // The stream ends with a meta-block that is both last and empty: one bit for
  // each, and nothing after them.
  self.bits.put(1, 1)
  self.bits.put(1, 1)
  let out : Array[Byte] = []
  for b in self.bits.drain() {
    out.push(b)
  }
  // The last two bits are not a byte yet: `finish` rounds the stream up, and the
  // decoder stops at the end marker rather than at the padding.
  for b in self.bits.finish() {
    out.push(b)
  }
  self.emit(out)
}

///|
/// A reader that is fed a piece at a time.
///
/// A meta-block cannot be decoded in halves, so the reader keeps the bytes it was
/// given and tries again when more arrive — starting from the last meta-block
/// boundary, because the bit cursor, the distance ring and the byte count are all
/// only consistent there. The retry threshold doubles what has to arrive before
/// the next attempt, so a body delivered a byte at a time is not quadratic.
struct Reader {
  limit : Int32
  /// Bytes received and not yet consumed by a decoded meta-block.
  mut pending : Array[Byte]
  /// The state at the last meta-block boundary: bit position, distance ring, and
  /// the number of bytes that boundary had produced.
  mut bit_at : Int32
  recent : FixedArray[Int32]
  mut max_backward : Int32
  mut produced : Int32
  /// How much has to have arrived before trying the meta-block again.
  mut retry : Int32
  /// Zero before the header, one between meta-blocks, two at the end marker.
  mut stage : Int32
  mut done : Bool
}

///|
pub fn Reader::new(limit? : Int32) -> Reader {
  {
    limit: match limit {
      Some(n) => n
      None => -1
    },
    pending: [],
    bit_at: 0,
    recent: [16, 15, 11, 4],
    max_backward: 0,
    produced: 0,
    retry: 0,
    stage: 0,
    done: false,
  }
}

///|
/// Drop the bytes whose bits have all been consumed, keeping the byte the cursor
/// stands in.
fn Reader::drop(self : Reader) -> Unit {
  let used = self.bit_at / 8
  if used <= 0 {
    return
  }
  let rest : Array[Byte] = []
  for i in used..<self.pending.length() {
    rest.push(self.pending[i])
  }
  self.pending = rest
  self.bit_at -= used * 8
}

///|
/// One attempt at the next meta-block. Returns what it produced, or nothing when
/// it needs more bytes than have arrived.
fn Reader::attempt(self : Reader) -> Bytes raise @moonzip.Refused {
  let data = Bytes::from_array(self.pending)
  let view = data[:]
  let dec = Dec::new(view, 0x7FFFFFFF)
  dec.bits.pos = self.bit_at
  dec.max_backward = self.max_backward
  for i in 0..<4 {
    dec.recent[i] = self.recent[i]
  }
  let more = dec.metablock()
  // A meta-block that ended the stream produces nothing and says so.
  let made = Bytes::from_array(dec.out)
  if self.limit >= 0 && self.produced + made.length() > self.limit {
    raise @moonzip.TooBig(limit=self.limit)
  }
  self.bit_at = dec.bits.pos
  self.max_backward = dec.max_backward
  for i in 0..<4 {
    self.recent[i] = dec.recent[i]
  }
  self.produced += made.length()
  if !more {
    self.done = true
  }
  made
}

///|
pub fn Reader::push(
  self : Reader,
  data : BytesView,
) -> Bytes raise @moonzip.Refused {
  if self.done {
    return b""
  }
  for b in data {
    self.pending.push(b)
  }
  let out : Array[Byte] = []
  if self.stage == 0 {
    let dec = Dec::new(Bytes::from_array(self.pending)[:], 0x7FFFFFFF)
    let read = try {
      dec.header()
      true
    } catch {
      @moonzip.Truncated(_) => false
      error => raise error
    }
    if !read {
      return b""
    }
    self.max_backward = dec.max_backward
    self.bit_at = dec.bits.pos
    self.stage = 1
  }
  while !self.done {
    if self.pending.length() * 8 - self.bit_at <= self.retry {
      break
    }
    let made = Some(self.attempt()) catch {
      @moonzip.Truncated(_) => None
      error => raise error
    }
    match made {
      Some(bytes) => {
        for b in bytes {
          out.push(b)
        }
        self.retry = 0
        self.drop()
      }
      None => {
        self.retry = if self.pending.length() > 0 {
          self.pending.length() * 2
        } else {
          1
        }
        break
      }
    }
  }
  Bytes::from_array(out)
}

///|
pub fn Reader::finish(self : Reader) -> Bytes raise @moonzip.Refused {
  let tail = self.push(b"")
  if !self.done {
    raise @moonzip.Truncated(at=self.pending.length())
  }
  tail
}
