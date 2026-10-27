// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A compressor that is fed a piece at a time.
///
/// bzip2 cannot emit anything until a block is complete — the sort needs all of
/// it — so what is held between calls is one block's worth of the run-length
/// stage plus a block of output. That is the format's own memory bound, not an
/// arbitrary one, and it is why the level is a memory setting.
///
/// ```moonbit nocheck
/// let w = @bzip2.Writer::new(level=9)
/// let mut out = w.push(part_one[:])
/// out = out + w.push(part_two[:])
/// out = out + w.finish()
/// ```
struct Writer {
  level : Int32
  sink : Sink
  /// The block being filled, after the run-length stage.
  mut block : Array[Byte]
  mut crc : BlockCrc
  mut combined : UInt32
  /// The byte the current run is made of, or -1 between runs.
  mut run_byte : Int32
  mut run_len : Int32
  mut closed : Bool
}

///|
pub fn Writer::new(level~ : Int32 = 9) -> Writer {
  let size = if level < 1 { 1 } else if level > 9 { 9 } else { level }
  let sink = Sink::new()
  for b in [0x42, 0x5A, 0x68, 0x30 + size] {
    sink.bits(b, 8)
  }
  {
    level: size,
    sink,
    block: [],
    crc: BlockCrc::new(),
    combined: 0U,
    run_byte: -1,
    run_len: 0,
    closed: false,
  }
}

///|
/// Fold the current run into the block, as four bytes and a count or as itself.
fn Writer::flush_run(self : Writer) -> Unit {
  if self.run_byte < 0 {
    return
  }
  let len = self.run_len
  for _ in 0..<len {
    self.crc.push_byte(self.run_byte)
  }
  if len < 4 {
    for _ in 0..<len {
      self.block.push(self.run_byte.to_byte())
    }
  } else {
    for _ in 0..<4 {
      self.block.push(self.run_byte.to_byte())
    }
    self.block.push((len - 4).to_byte())
  }
  self.run_byte = -1
  self.run_len = 0
}

///|
/// Hand the block over and start another.
fn Writer::emit(self : Writer) -> Unit {
  let crc = self.crc.finish()
  write_block(self.sink, self.block, crc)
  self.combined = ((self.combined << 1) | (self.combined >> 31)) ^ crc
  self.block = []
  self.crc = BlockCrc::new()
}

///|
pub fn Writer::push(self : Writer, data : BytesView) -> Bytes {
  if self.closed {
    return b""
  }
  let max = block_size(self.level)
  for b in data {
    let byte = b.to_int()
    if self.run_byte == byte && self.run_len < 255 {
      self.run_len += 1
    } else {
      self.flush_run()
      self.run_byte = byte
      self.run_len = 1
    }
    // The check comes after the run is folded in, and the run is atomic, so a
    // block can pass its limit by the four bytes and a count of one run. The
    // format allows it; a block is a block, not a fixed-size record.
    if self.block.length() >= max {
      self.emit()
    }
  }
  self.sink.drain()
}

///|
pub fn Writer::finish(self : Writer) -> Bytes {
  if self.closed {
    return b""
  }
  self.closed = true
  self.flush_run()
  if self.block.length() > 0 {
    self.emit()
  }
  for b in end_marker {
    self.sink.bits(b, 8)
  }
  self.sink.word(self.combined)
  self.sink.finish()
}

///|
/// A reader that is fed a piece at a time.
///
/// A bzip2 block cannot be decoded until all of it has arrived, so a push that
/// does not complete a block produces nothing. What survives between pushes is
/// the bit position of the block that is being waited for — a *bit* position, not
/// a byte one, because the format does not pad between blocks: the next marker
/// starts at the next bit, which is why this reader keeps an accumulator rather
/// than an offset.
struct Reader {
  mut level : Int32
  checksum : Bool
  limit : Int32
  /// Bytes received but not yet decoded.
  mut buffer : Array[Byte]
  /// Where in them the reader is, in bytes loaded, and the bits still pending.
  mut at : Int32
  mut acc : UInt32
  mut held : Int32
  mut combined : UInt32
  /// Zero before the header, one between blocks, two once the trailer is read.
  mut stage : Int32
  /// How much has to have arrived before trying the block again. Doubling it
  /// keeps a body delivered a byte at a time from turning into quadratic work.
  mut retry : Int32
}

///|
pub fn Reader::new(checksum~ : Bool = true, limit? : Int32) -> Reader {
  {
    level: 0,
    checksum,
    limit: match limit {
      Some(n) => n
      None => -1
    },
    buffer: [],
    at: 0,
    acc: 0U,
    held: 0,
    combined: 0U,
    stage: 0,
    retry: 0,
  }
}

///|
/// A bit reader over the buffer as it is now, placed where the last block left
/// off. A push rebuilds this because the buffer may have grown in between.
fn Reader::bits(self : Reader) -> Bits {
  Bits::{
    data: Bytes::from_array(self.buffer)[:],
    at: self.at,
    acc: self.acc,
    held: self.held,
  }
}

///|
/// Adopt the position a successful read ended at.
fn Reader::settle(self : Reader, bits : Bits) -> Unit {
  self.at = bits.at
  self.acc = bits.acc
  self.held = bits.held
}

///|
/// Drop the bytes whose bits have all been read, keeping the partial one.
///
/// The accumulator holds the low `held` bits of the byte at `at - 1`, so dropping
/// everything before it keeps the reader exactly where it was and lets the buffer
/// stay the size of a block rather than the size of the stream.
fn Reader::drop_consumed(self : Reader) -> Unit {
  let used = self.at - (if self.held > 0 { 1 } else { 0 })
  if used <= 0 {
    return
  }
  let rest : Array[Byte] = []
  for i in used..<self.buffer.length() {
    rest.push(self.buffer[i])
  }
  self.buffer = rest
  self.at -= used
}

///|
pub fn Reader::push(
  self : Reader,
  data : BytesView,
) -> Bytes raise @moonzip.Refused {
  if self.stage == 2 {
    return b""
  }
  for b in data {
    self.buffer.push(b)
  }
  let out : Array[Byte] = []
  if self.stage == 0 {
    if self.buffer.length() < 4 {
      return b""
    }
    if self.buffer[0].to_int() != 0x42 ||
      self.buffer[1].to_int() != 0x5A ||
      self.buffer[2].to_int() != 0x68 {
      raise @moonzip.Header(at=0, what="this is not a bzip2 stream")
    }
    let level_byte = self.buffer[3].to_int()
    if level_byte < 0x31 || level_byte > 0x39 {
      raise @moonzip.Header(
        at=3,
        what="a block size that is not a digit from one to nine",
      )
    }
    self.level = level_byte - 0x30
    self.at = 4
    self.acc = 0
    self.held = 0
    self.stage = 1
  }
  while self.stage == 1 {
    let room = self.buffer.length() - self.at
    if room <= 0 || room <= self.retry {
      break
    }
    let bits = self.bits()
    // -1 means "not enough bytes yet"; the position is left where it was so the
    // next push starts the same block again rather than half of it.
    let mut kind = -1
    let mut block = b""
    let mut stamp = 0U
    let mut want = 0U
    try {
      match marker(bits) {
        None =>
          raise @moonzip.Header(
            at=self.at,
            what="a block marker that is neither the block nor the end of stream",
          )
        Some(1) => {
          kind = 1
          want = match bits.take_word() {
            Some(v) => v
            None => raise @moonzip.Truncated(at=bits.used())
          }
        }
        Some(_) => {
          let (made, crc) = read_block(bits, self.level)
          block = made
          stamp = crc
          kind = 0
        }
      }
    } catch {
      @moonzip.Truncated(_) => kind = -1
      error => raise error
    }
    if kind < 0 {
      self.retry = if room > 0 { room * 2 } else { 1 }
      break
    }
    if kind == 1 {
      if self.checksum && want != self.combined {
        raise @moonzip.Checksum(want~, got=self.combined)
      }
      self.settle(bits)
      self.stage = 2
      break
    }
    if self.limit >= 0 && out.length() + block.length() > self.limit {
      raise @moonzip.TooBig(limit=self.limit)
    }
    self.combined = ((self.combined << 1) | (self.combined >> 31)) ^ stamp
    self.settle(bits)
    self.retry = 0
    for b in block {
      out.push(b)
    }
    self.drop_consumed()
  }
  Bytes::from_array(out)
}

///|
pub fn Reader::finish(self : Reader) -> Bytes raise @moonzip.Refused {
  if self.stage == 2 {
    return b""
  }
  // The retry threshold exists to keep a body delivered a byte at a time from
  // re-reading a block on every byte. At the end there is no reason to wait any
  // longer: whatever has arrived is everything that is coming.
  self.retry = 0
  let tail = self.push(b"")
  if self.stage != 2 {
    raise @moonzip.Truncated(at=self.buffer.length())
  }
  tail
}
