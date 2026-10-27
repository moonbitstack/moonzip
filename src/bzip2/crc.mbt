// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// bzip2's CRC-32.
///
/// The same polynomial as gzip's, computed the other way round: not reflected,
/// and the byte enters at the top rather than the bottom. Initial and final
/// values are both all ones, so a block of nothing hashes to zero. It lives here
/// rather than in the root package because no other format in this module uses
/// this orientation, and a checksum shared by one caller is not shared.
fn crc_byte(state : UInt32, byte : Int32) -> UInt32 {
  let mut c = state ^ (byte.reinterpret_as_uint() << 24)
  for _ in 0..<8 {
    c = if (c & 0x80000000U) != 0U { (c << 1) ^ 0x04C11DB7U } else { c << 1 }
  }
  c
}

///|
/// The running value for a stream of bytes.
priv struct BlockCrc {
  mut state : UInt32
}

///|
fn BlockCrc::new() -> BlockCrc {
  { state: 0xFFFFFFFFU, }
}

///|
fn BlockCrc::push_byte(self : BlockCrc, byte : Int32) -> Unit {
  self.state = crc_byte(self.state, byte)
}

///|
fn BlockCrc::finish(self : BlockCrc) -> UInt32 {
  self.state ^ 0xFFFFFFFFU
}
