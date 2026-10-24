// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// CRC-32 as gzip, ZIP and PNG use it (RFC 1952 §8): the reflected form of the
/// IEEE 802.3 polynomial, starting and ending complemented.
///
/// It lives at the root rather than beside one container because two of them
/// specify it — `gzip` puts it in the trailer, `zip` in every entry's header and
/// again in the central directory — and one of them should not have to import
/// the other to reach it. When the checksum package in `mooncrypt` lands, this
/// moves there and is re-exported from here.
pub fn crc32(data : BytesView) -> UInt32 {
  let sum = Crc::new()
  sum.push(data)
  sum.finish()
}

///|
/// The same checksum, taken a piece at a time.
///
/// A container that compresses a body it never holds cannot checksum it in one
/// call either: the streaming writers in `gzip` and `zip` keep one of these
/// beside their compressor and hand it each chunk as it goes past.
pub(all) struct Crc {
  mut state : UInt32
}

///|
/// The running state: complemented, as the algorithm starts.
pub fn Crc::new() -> Crc {
  { state: 0xFFFFFFFFU, }
}

///|
/// Fold a chunk into the running state.
pub fn Crc::push(self : Crc, data : BytesView) -> Unit {
  for b in data {
    self.state = self.state ^ b.to_uint()
    for _ in 0..<8 {
      self.state = if (self.state & 1U) != 0U {
        (self.state >> 1) ^ 0xEDB88320U
      } else {
        self.state >> 1
      }
    }
  }
}

///|
/// The checksum itself: the state, complemented back.
pub fn Crc::finish(self : Crc) -> UInt32 {
  self.state ^ 0xFFFFFFFFU
}

// ------------------------------------------------------------------- adler-32

///|
/// Adler-32 (RFC 1950 §9): two running sums modulo the largest prime below
/// 65536. Cheaper than a CRC and weaker, which is the trade zlib made.
pub fn adler32(data : BytesView) -> UInt32 {
  let sum = Adler::new()
  sum.push(data)
  sum.finish()
}

///|
/// The same checksum, taken a piece at a time, for a body that is never held.
pub(all) struct Adler {
  mut a : UInt32
  mut b : UInt32
}

///|
/// The running state: `a` starts at one, `b` at nothing.
pub fn Adler::new() -> Adler {
  { a: 1U, b: 0U, }
}

///|
/// Fold a chunk into the running state.
///
/// 5552 is the most bytes that can be added before the sums could overflow
/// 32 bits, so the modulo runs once a block instead of once a byte.
pub fn Adler::push(self : Adler, data : BytesView) -> Unit {
  let mut at = 0
  let n = data.length()
  while at < n {
    let stop = if n - at < 5552 { n } else { at + 5552 }
    while at < stop {
      self.a += data[at].to_uint()
      self.b += self.a
      at += 1
    }
    self.a = self.a % 65521U
    self.b = self.b % 65521U
  }
}

///|
/// The checksum itself: `b` in the high half, `a` in the low.
pub fn Adler::finish(self : Adler) -> UInt32 {
  ((self.b % 65521U) << 16) | (self.a % 65521U)
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
