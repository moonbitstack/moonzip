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
pub fn crc32(data : BytesView) -> UInt {
  let mut crc = 0xFFFFFFFFU
  for b in data {
    crc = crc ^ b.to_uint()
    for _ in 0..<8 {
      crc = if (crc & 1U) != 0U { (crc >> 1) ^ 0xEDB88320U } else { crc >> 1 }
    }
  }
  crc ^ 0xFFFFFFFFU
}
