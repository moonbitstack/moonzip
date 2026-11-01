// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// CRC-32 as gzip, ZIP and PNG use it (RFC 1952): the reflected form of the
/// IEEE 802.3 polynomial, starting and ending complemented.
///
/// The folding is `mooncrypt/sum/crc32`; it is reached from here so the formats
/// that specify it — `gzip` in its trailer, `zip` in every entry and again in the
/// central directory — find it in one place instead of each importing the other.
pub fn crc32(data : BytesView) -> UInt32 {
  @crc32.crc32(data)
}

///|
/// Adler-32 (RFC 1950): two running sums modulo the largest prime below 65536.
/// Cheaper than a CRC and weaker, which is the trade zlib made. The folding is
/// `mooncrypt/sum/adler32`, reached from here for the same reason `crc32` is.
pub fn adler32(data : BytesView) -> UInt32 {
  @adler32.adler32(data)
}

///|
/// CRC-32 taken a piece at a time, for a body that is never held whole.
///
/// A container that compresses a body it never holds cannot checksum it in one
/// call either: the streaming writers in `gzip` and `zip` keep one of these
/// beside their compressor and hand it each chunk as it goes past. The running
/// state and the folding come from `mooncrypt/sum/crc32`.
pub(all) struct Crc {
  inner : @crc32.Crc32
}

///|
pub fn Crc::new() -> Crc {
  { inner: @crc32.Crc32::new(), }
}

///|
pub fn Crc::push(self : Crc, data : BytesView) -> Unit {
  self.inner.update(data)
}

///|
pub fn Crc::finish(self : Crc) -> UInt32 {
  self.inner.value()
}

///|
/// Adler-32 taken a piece at a time, for a body that is never held whole. The
/// running state and the folding come from `mooncrypt/sum/adler32`.
pub(all) struct Adler {
  inner : @adler32.Adler32
}

///|
pub fn Adler::new() -> Adler {
  { inner: @adler32.Adler32::new(), }
}

///|
pub fn Adler::push(self : Adler, data : BytesView) -> Unit {
  self.inner.update(data)
}

///|
pub fn Adler::finish(self : Adler) -> UInt32 {
  self.inner.value()
}

// ------------------------------------------------------------------- crc-32c

///|
/// CRC-32C, the Castagnoli polynomial: the checksum that has hardware support on
/// every x86 since Nehalem and every ARM since v8, which is why Snappy and iSCSI
/// chose it over the older CRC-32 that gzip and ZIP use.
///
/// It lives here beside the other two for the same reason they are here: it is a
/// checksum the formats specify, not something a format invents, and a caller
/// comparing two of them should find them in one place.
pub fn crc32c(data : BytesView) -> UInt32 {
  let sum = Castagnoli::new()
  sum.push(data)
  sum.finish()
}

///|
/// CRC-32C taken a piece at a time, for a body that is never held whole.
pub(all) struct Castagnoli {
  mut state : UInt32
}

///|
pub fn Castagnoli::new() -> Castagnoli {
  { state: 0xFFFFFFFFU, }
}

///|
pub fn Castagnoli::push(self : Castagnoli, data : BytesView) -> Unit {
  for b in data {
    self.state = self.state ^ b.to_uint()
    for _ in 0..<8 {
      self.state = if (self.state & 1U) != 0U {
        (self.state >> 1) ^ 0x82F63B78U
      } else {
        self.state >> 1
      }
    }
  }
}

///|
pub fn Castagnoli::finish(self : Castagnoli) -> UInt32 {
  self.state ^ 0xFFFFFFFFU
}

///|
/// The mask Snappy applies to a CRC-32C before putting it in a frame, so that a
/// checksum never looks like the length in front of it — and so that a reader
/// that echoes the bytes back cannot be fooled into accepting them.
pub fn mask_crc32c(sum : UInt32) -> UInt32 {
  ((sum >> 15) | (sum << 17)) + 0xA282EAD8U
}
