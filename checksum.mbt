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
