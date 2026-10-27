// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A cursor over the bits of a stream, least significant bit of each byte first.
///
/// Brotli has no alignment rule, no padding between meta-blocks and no way to
/// resume in the middle of one, so unlike the other packages here a reader can
/// be a plain cursor over a buffer that is already complete. That is what this
/// is: no push, no retained window, no "needs more input".
priv struct Bits {
  data : BytesView
  /// Bit offset of the next bit to read, counted from the start of `data`.
  mut pos : Int32
  /// Total bits available; `pos` never passes it.
  limit : Int32
}

///|
fn Bits::new(data : BytesView) -> Bits {
  { data, pos: 0, limit: data.length() * 8, }
}

///|
/// The byte the reader is standing in, for error messages.
fn Bits::at(self : Bits) -> Int32 {
  if self.pos >= self.limit {
    self.limit / 8
  } else {
    self.pos / 8
  }
}

///|
fn Bits::byte(self : Bits, index : Int32) -> Int32 {
  if index >= self.data.length() {
    0
  } else {
    self.data[index].to_int()
  }
}

///|
/// `n` bits, `n <= 24`, the first one read landing in the lowest place.
///
/// The four-byte window is what keeps this from being a bit-at-a-time loop:
/// one shift and one mask instead of `n` iterations, which matters because a
/// literal costs one of these and a megabyte of text is a million of them.
fn Bits::take(self : Bits, n : Int32) -> Int32 raise @moonzip.Refused {
  if n == 0 {
    return 0
  }
  if n > 24 {
    raise @moonzip.Header(at=self.at(), what="a \{n}-bit field is not a field")
  }
  if self.pos + n > self.limit {
    raise @moonzip.Truncated(at=self.at())
  }
  let byte = self.pos >> 3
  let mut word = 0
  let mut k = 3
  while k >= 0 {
    word = (word << 8) | self.byte(byte + k)
    k -= 1
  }
  let value = (word >> (self.pos & 7)) & ((1 << n) - 1)
  self.pos += n
  value
}

///|
/// One bit, as a boolean-shaped integer. Kept separate from `take` because the
/// Huffman walk below is a tight loop over single bits.
fn Bits::bit(self : Bits) -> Int32 raise @moonzip.Refused {
  if self.pos >= self.limit {
    raise @moonzip.Truncated(at=self.at())
  }
  let value = (self.data[self.pos >> 3].to_int() >> (self.pos & 7)) & 1
  self.pos += 1
  value
}

///|
/// Skip to the next byte boundary. Used by uncompressed meta-blocks, which are
/// the only place brotli pads.
fn Bits::align(self : Bits) -> Unit raise @moonzip.Refused {
  let skip = (8 - (self.pos & 7)) & 7
  if self.pos + skip > self.limit {
    raise @moonzip.Truncated(at=self.at())
  }
  let padded = self.pos + skip
  self.pos = padded
}

///|
/// Copy `n` whole bytes out of the stream, starting at the current position,
/// which must be a byte boundary. Uncompressed meta-blocks are exactly this.
fn Bits::bytes(self : Bits, n : Int32) -> Bytes raise @moonzip.Refused {
  if (self.pos & 7) != 0 {
    raise @moonzip.Header(at=self.at(), what="a raw block that starts mid-byte")
  }
  let start = self.pos >> 3
  if start + n > self.data.length() {
    raise @moonzip.Truncated(at=self.data.length())
  }
  let out = FixedArray::make(n, b'\x00')
  for i in 0..<n {
    out[i] = self.data[start + i]
  }
  self.pos += n * 8
  Bytes::from_array(out)
}

///|
/// A bit sink, least significant bit first, mirroring `Bits` above.
///
/// Brotli has no trailing padding to write: the stream ends on the last bit of
/// the last meta-block header, so `finish` flushes whatever is pending and does
/// not round up.
priv struct Writer {
  out : Array[Byte]
  mut acc : Int32
  mut nbits : Int32
}

///|
fn Writer::new() -> Writer {
  { out: [], acc: 0, nbits: 0, }
}

///|
fn Writer::put(self : Writer, value : Int32, n : Int32) -> Unit {
  if n == 0 {
    return
  }
  let mut v = value & ((1 << n) - 1)
  let mut left = n
  while left > 0 {
    let room = 8 - self.nbits
    let take = if left < room { left } else { room }
    self.acc = self.acc | ((v & ((1 << take) - 1)) << self.nbits)
    self.nbits += take
    v = v >> take
    left -= take
    if self.nbits == 8 {
      self.out.push(self.acc.to_byte())
      self.acc = 0
      self.nbits = 0
    }
  }
}

///|
fn Writer::finish(self : Writer) -> Bytes {
  if self.nbits > 0 {
    self.out.push(self.acc.to_byte())
    self.acc = 0
    self.nbits = 0
  }
  Bytes::from_array(self.out)
}
