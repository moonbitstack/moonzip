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
  /// The bytes written so far, in a buffer that doubles. A growable array would
  /// work and would check its capacity on every byte; this check is one compare
  /// against a length the compiler can keep in a register.
  mut out : FixedArray[Byte]
  mut len : Int32
  mut acc : Int32
  mut held : Int32
  /// Every bit written, padding included — what a candidate block is measured
  /// against when the writer chooses between forms.
  mut count : Int32
}

///|
fn BitWriter::new() -> BitWriter {
  { out: FixedArray::make(4096, b'\x00'), len: 0, acc: 0, held: 0, count: 0, }
}

///|
fn BitWriter::grow(self : BitWriter) -> Unit {
  let next = FixedArray::make(self.out.length() * 2, b'\x00')
  next.unsafe_blit(0, self.out, 0, self.len)
  self.out = next
}

///|
/// The low `count` bits of `value`, least significant first.
fn BitWriter::bits(self : BitWriter, value : Int32, count : Int32) -> Unit {
  self.acc = self.acc | ((value & ((1 << count) - 1)) << self.held)
  self.held = self.held + count
  self.count = self.count + count
  while self.held >= 8 {
    if self.len >= self.out.length() {
      self.grow()
    }
    self.out.unsafe_set(self.len, (self.acc & 0xFF).to_byte())
    self.len = self.len + 1
    self.acc = self.acc >> 8
    self.held = self.held - 8
  }
}

///|
/// A Huffman code goes out most significant bit first, against the stream's own
/// order — so it is reversed on the way in (§3.1.1).
///
/// The writer proper reverses each code once, when it builds the table, and hands
/// the result to `bits`. This is for the callers that have a code and a width and
/// nothing else — the white-box tests, and nothing on the hot path.
fn BitWriter::huff(self : BitWriter, code : Int32, len : Int32) -> Unit {
  let mut flipped = 0
  for i in 0..<len {
    flipped = (flipped << 1) | ((code >> i) & 1)
  }
  self.bits(flipped, len)
}

///|
/// Another writer's bits, appended where this one stands.
///
/// A candidate block is written to a scratch writer to be measured. Writing it
/// again into the stream is one pass over the tokens; splicing the scratch bytes
/// in is one pass over the bytes, which on a block of a hundred kilobytes is
/// several times cheaper and produces exactly the same stream.
fn BitWriter::append(self : BitWriter, other : BitWriter) -> Unit {
  for i in 0..<other.len {
    self.bits(other.out.unsafe_get(i).to_int(), 8)
  }
  if other.held > 0 {
    self.bits(other.acc, other.held)
  }
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
  let n = to - from
  while self.len + n > self.out.length() {
    self.grow()
  }
  let out = self.out
  let at = self.len
  for i in 0..<n {
    out.unsafe_set(at + i, buf.unsafe_get(from + i))
  }
  self.len = at + n
  self.count += n * 8
}

///|
/// End the current block without ending the stream: the empty stored block a
/// synchronising flush is. Three header bits, padding to the byte boundary, then
/// a length of zero and its complement — the `00 00 FF FF` every streaming
/// compressor recognises (RFC 1951 §3.2.4, and zlib's own flush).
fn BitWriter::sync(self : BitWriter) -> Unit {
  self.bits(0, 3)
  while self.held > 0 {
    self.bits(0, 1)
  }
  self.bits(0, 16)
  self.bits(0xFFFF, 16)
}

///|
/// Take the bytes written so far, leaving the partial byte in the accumulator.
/// This is what a streaming writer hands its caller.
fn BitWriter::take(self : BitWriter) -> Bytes {
  let made = Bytes::from_array(self.out[0:self.len])
  self.len = 0
  made
}

///|
/// Pad the last byte and take everything. The stream is over.
fn BitWriter::finish(self : BitWriter) -> Bytes {
  if self.held > 0 {
    self.count += 8 - self.held
    if self.len >= self.out.length() {
      self.grow()
    }
    self.out.unsafe_set(self.len, (self.acc & 0xFF).to_byte())
    self.len = self.len + 1
    self.acc = 0
    self.held = 0
  }
  let made = Bytes::from_array(self.out[0:self.len])
  self.len = 0
  made
}

///|
/// The reading side, over a buffer that grows as input arrives.
///
/// `pos` is the next byte to pull into the accumulator; `held` is how many bits
/// of already-pulled bytes have not been consumed. A read that runs past the
/// end of the buffer returns `None` rather than raising, because the byte it
/// wants may be in the next chunk — the caller decides whether the stream is
/// over, and only then is running out an error.
///
/// The accumulator is sixty-four bits wide and the buffer is `Bytes` rather than
/// an array so that a refill is one unaligned word load: the decoder's inner loop
/// pulls eight bytes at a time and keeps the whole of a code plus its extra bits
/// there, which is what keeps the per-symbol work down to one table lookup.
priv struct BitReader {
  mut buf : Bytes
  mut pos : Int32
  mut acc : UInt64
  mut held : Int32
}

///|
fn BitReader::new() -> BitReader {
  { buf: b"", pos: 0, acc: 0UL, held: 0, }
}

///|
/// More input. What has been pulled into the accumulator is dropped, since the
/// accumulator is the only place those bits still exist.
fn BitReader::push(self : BitReader, data : BytesView) -> Unit {
  // Whole bytes the accumulator holds are un-pulled first: `pos` is the next
  // byte not yet looked at, and everything below it is about to be dropped. A
  // look-ahead leaves up to seven such bytes behind, and dropping them loses
  // input that has not been decoded yet.
  let whole = self.held / 8
  if whole > 0 {
    self.pos -= whole
    self.held -= whole * 8
    self.acc = self.acc & ((1UL << self.held) - 1UL)
  }
  let extra = data.length()
  let left = self.buf.length() - self.pos
  if extra > 0 || self.pos > 0 {
    // One allocation and two blits. Growing an array a byte at a time costs the
    // capacity check and the call that a blit does not, and this runs over every
    // byte that arrives.
    let kept = FixedArray::make(left + extra, b'\x00')
    if left > 0 {
      for i in 0..<left {
        kept.unsafe_set(i, self.buf.unsafe_get(self.pos + i))
      }
    }
    for i in 0..<extra {
      kept.unsafe_set(left + i, data.unsafe_get(i))
    }
    self.buf = Bytes::from_array(kept[:])
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
    self.acc = self.acc |
      (self.buf.unsafe_get(self.pos).to_uint64() << self.held)
    self.pos += 1
    self.held += 8
  }
  let value = (self.acc & ((1UL << count) - 1UL)).to_int()
  self.acc = self.acc >> count
  self.held -= count
  Some(value)
}

///|
/// `count` bits, or -1 when the buffer does not hold that many.
///
/// The `Option` form above is right where a read happens once per block — a
/// header, a stored length — and wrong where it happens twice per match, which is
/// the inner loop: every call there builds a value the caller only wants to test.
/// A sentinel costs nothing because no field in the format is sixteen bits wide
/// and able to hold the sign bit.
fn BitReader::take(self : BitReader, count : Int32) -> Int32 {
  while self.held < count {
    if self.pos >= self.buf.length() {
      return -1
    }
    self.acc = self.acc |
      (self.buf.unsafe_get(self.pos).to_uint64() << self.held)
    self.pos += 1
    self.held += 8
  }
  let value = (self.acc & ((1UL << count) - 1UL)).to_int()
  self.acc = self.acc >> count
  self.held -= count
  value
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
/// format never mentions.
///
/// Only the partial byte is padding. A look-ahead may have pulled whole bytes into
/// the accumulator, and those are real data that the stored block about to follow
/// reads straight out of the buffer — so they are handed back by rewinding `pos`,
/// which is safe because nothing truncates the buffer except `push`, and that only
/// drops what is already behind `pos`.
fn BitReader::align(self : BitReader) -> Unit {
  let whole = self.held / 8
  if whole > 0 {
    self.pos -= whole
  }
  self.acc = 0UL
  self.held = 0
}

///|
/// Copy whole bytes straight out of the buffer, up to `count` of them, and say
/// how many there were. A stored block's payload is copied this way, and a
/// chunk boundary in the middle of one is not an error — the rest arrives with
/// the next push. Only valid at a byte boundary, which is where a stored block
/// is.
///
/// Eight bytes at a time: the copy is the whole cost of a stored block, and a
/// byte loop through a field of `self` reloads the buffer pointer on every
/// iteration because a store through `dst` may in principle have written it.
fn BitReader::take_bytes(
  self : BitReader,
  dst : FixedArray[Byte],
  at : Int32,
  count : Int32,
) -> Int32 {
  let buf = self.buf
  let pos = self.pos
  let left = buf.length() - pos
  let taken = if left < count { left } else { count }
  let mut i = 0
  while i + 8 <= taken {
    dst.unsafe_write_uint64_le(at + i, buf.unsafe_read_uint64_le(pos + i))
    i += 8
  }
  while i < taken {
    dst.unsafe_set(at + i, buf.unsafe_get(pos + i))
    i += 1
  }
  self.pos = pos + taken
  taken
}
