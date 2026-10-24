// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// xxHash-32, which the LZ4 frame format uses for its header and content
/// checksums and nothing else in this library uses at all.
///
/// Four lanes of multiply-and-rotate over sixteen bytes at a time, then an
/// avalanche that mixes the last few bytes back in. It is not a cryptographic
/// hash and does not pretend to be: it is fast, and a frame checksum needs speed
/// and nothing more.
let prime1 : UInt32 = 2654435761U

///|
let prime2 : UInt32 = 2246822519U

///|
let prime3 : UInt32 = 3266489917U

///|
let prime4 : UInt32 = 668265263U

///|
let prime5 : UInt32 = 374761393U

///|
fn rotl(value : UInt32, count : Int32) -> UInt32 {
  // A shift by thirty-two is undefined, so a rotate by zero is spelled out.
  if count == 0 {
    value
  } else {
    (value << count) | (value >> (32 - count))
  }
}

///|
fn read32(data : BytesView, at : Int32) -> UInt32 {
  data[at].to_uint() |
  (data[at + 1].to_uint() << 8) |
  (data[at + 2].to_uint() << 16) |
  (data[at + 3].to_uint() << 24)
}

///|
fn round(acc : UInt32, lane : UInt32) -> UInt32 {
  rotl(acc + lane * prime2, 13) * prime1
}

///|
/// The hash itself.
pub fn xxh32(data : BytesView, seed~ : UInt32 = 0U) -> UInt32 {
  let n = data.length()
  let mut at = 0
  let mut h = if n >= 16 {
    let mut v1 = seed + prime1 + prime2
    let mut v2 = seed + prime2
    let mut v3 = seed
    let mut v4 = seed - prime1
    while at + 16 <= n {
      v1 = round(v1, read32(data, at))
      v2 = round(v2, read32(data, at + 4))
      v3 = round(v3, read32(data, at + 8))
      v4 = round(v4, read32(data, at + 12))
      at += 16
    }
    rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18)
  } else {
    seed + prime5
  }
  h = h + n.reinterpret_as_uint()
  while at + 4 <= n {
    h = rotl(h + read32(data, at) * prime3, 17) * prime4
    at += 4
  }
  while at < n {
    h = rotl(h + data[at].to_uint() * prime5, 11) * prime1
    at += 1
  }
  h = h ^ (h >> 15)
  h = h * prime2
  h = h ^ (h >> 13)
  h = h * prime3
  h ^ (h >> 16)
}
