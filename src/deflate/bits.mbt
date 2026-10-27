// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The bit layer, where DEFLATE's two orders meet.
///
/// Every field in the format — a block header, an extra-bits value, a stored
/// length — goes out least significant bit first. A Huffman code goes out most
/// significant bit first (RFC 1951 §3.1.1), so it is reversed on the way in.
/// Nothing here knows what a block is.
priv struct BitWriter {
  out : Array[Byte]
  mut acc : Int32
  mut held : Int32
  /// Every bit written, padding included — what a candidate block is measured
  /// against when the writer chooses between forms.
  mut count : Int32
}

///|
fn BitWriter::new() -> BitWriter {
  { out: [], acc: 0, held: 0, count: 0, }
}

///|
/// The low `count` bits of `value`, least significant first.
fn BitWriter::bits(self : BitWriter, value : Int32, count : Int32) -> Unit {
  self.acc = self.acc | ((value & ((1 << count) - 1)) << self.held)
  self.held += count
  self.count += count
  while self.held >= 8 {
    self.out.push((self.acc & 0xFF).to_byte())
    self.acc = self.acc >> 8
    self.held -= 8
  }
}

///|
/// A Huffman code goes out most significant bit first, against the stream's own
/// order — so it is reversed on the way in (§3.1.1).
fn BitWriter::huff(self : BitWriter, code : Int32, len : Int32) -> Unit {
  let mut flipped = 0
  for i in 0..<len {
    flipped = (flipped << 1) | ((code >> i) & 1)
  }
  self.bits(flipped, len)
}

///|
/// A run of whole bytes, which may only be handed over at a byte boundary — a
/// stored block's payload after it has aligned, and nothing else.
fn BitWriter::raw_range(
  self : BitWriter,
  buf : Array[Byte],
  from : Int32,
  to : Int32,
) -> Unit {
  for i in from..<to {
    self.out.push(buf[i])
  }
  self.count += (to - from) * 8
}

///|
/// Take the bytes written so far, leaving the partial byte in the accumulator.
/// This is what a streaming writer hands its caller.
fn BitWriter::take(self : BitWriter) -> Bytes {
  let made = Bytes::from_array(self.out)
  self.out.clear()
  made
}

///|
/// Pad the last byte and take everything. The stream is over.
fn BitWriter::finish(self : BitWriter) -> Bytes {
  if self.held > 0 {
    self.count += 8 - self.held
    self.out.push((self.acc & 0xFF).to_byte())
    self.acc = 0
    self.held = 0
  }
  Bytes::from_array(self.out)
}

///|
/// The reading side, over a buffer that grows as input arrives.
///
/// `pos` is the next byte to pull into the accumulator; `held` is how many bits
/// of already-pulled bytes have not been consumed. A read that runs past the
/// end of the buffer returns `None` rather than raising, because the byte it
/// wants may be in the next chunk — the caller decides whether the stream is
/// over, and only then is running out an error.
priv struct BitReader {
  mut buf : Array[Byte]
  mut pos : Int32
  mut acc : Int32
  mut held : Int32
}

///|
fn BitReader::new() -> BitReader {
  { buf: [], pos: 0, acc: 0, held: 0, }
}

///|
/// More input. What has been pulled into the accumulator is dropped, since the
/// accumulator is the only place those bits still exist.
fn BitReader::push(self : BitReader, data : BytesView) -> Unit {
  for b in data {
    self.buf.push(b)
  }
  if self.pos > 0 {
    let kept : Array[Byte] = []
    for i in self.pos..<self.buf.length() {
      kept.push(self.buf[i])
    }
    self.buf = kept
    self.pos = 0
  }
}

///|
/// `count` bits, or `None` if the buffer does not hold that many.
fn BitReader::bits(self : BitReader, count : Int32) -> Int32? {
  while self.held < count {
    if self.pos >= self.buf.length() {
      return None
    }
    self.acc = self.acc | (self.buf[self.pos].to_int() << self.held)
    self.pos += 1
    self.held += 8
  }
  let value = self.acc & ((1 << count) - 1)
  self.acc = self.acc >> count
  self.held -= count
  Some(value)
}

///|
/// Bytes still buffered and not yet pulled into the accumulator.
fn BitReader::remaining(self : BitReader) -> Int32 {
  self.buf.length() - self.pos
}

///|
/// Where the reader was when it gave up, in bytes from the start of the stream
/// — enough to find the damage in a file, which "corrupt data" is not.
fn BitReader::at(self : BitReader) -> Int32 {
  self.pos
}

///|
/// Drop to a byte boundary, which a stored block requires and the rest of the
/// format never mentions. The bits skipped are the tail of a byte already
/// pulled, so `pos` does not move.
fn BitReader::align(self : BitReader) -> Unit {
  self.acc = 0
  self.held = 0
}

///|
/// Copy whole bytes straight out of the buffer, up to `count` of them, and say
/// how many there were. A stored block's payload is copied this way, and a
/// chunk boundary in the middle of one is not an error — the rest arrives with
/// the next push. Only valid at a byte boundary, which is where a stored block
/// is.
fn BitReader::take_bytes(
  self : BitReader,
  out : Array[Byte],
  count : Int32,
) -> Int32 {
  let mut taken = 0
  while taken < count && self.pos < self.buf.length() {
    out.push(self.buf[self.pos])
    self.pos += 1
    taken += 1
  }
  taken
}
