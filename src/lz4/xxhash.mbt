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
/// The same hash, fed a piece at a time.
///
/// A frame's content checksum covers the bytes before they were compressed, so a
/// writer that never holds the whole body needs the hash as a state machine. What
/// is left between calls is the four lanes, the length so far, and the bytes that
/// did not fill a sixteen-byte stripe — which is what the four-byte and one-byte
/// loops of the one-shot form would have read.
///
/// ```moonbit nocheck
/// let h = @lz4.Xxh32::new()
/// h.push(part_one[:])
/// h.push(part_two[:])
/// let sum = h.finish()
/// ```
pub(all) struct Xxh32 {
  seed : UInt32
  mut v1 : UInt32
  mut v2 : UInt32
  mut v3 : UInt32
  mut v4 : UInt32
  mut total : Int32
  /// Fewer than sixteen bytes, waiting for the stripe they belong to.
  mut held : Array[Byte]
}

///|
pub fn Xxh32::new(seed~ : UInt32 = 0U) -> Xxh32 {
  {
    seed,
    v1: seed + prime1 + prime2,
    v2: seed + prime2,
    v3: seed,
    v4: seed - prime1,
    total: 0,
    held: [],
  }
}

///|
pub fn Xxh32::push(self : Xxh32, data : BytesView) -> Unit {
  self.total += data.length()
  let buf : Array[Byte] = []
  for b in self.held {
    buf.push(b)
  }
  for b in data {
    buf.push(b)
  }
  let mut at = 0
  while at + 16 <= buf.length() {
    let stripe = Bytes::from_array(buf[at:at + 16])
    self.v1 = round(self.v1, read32(stripe[:], 0))
    self.v2 = round(self.v2, read32(stripe[:], 4))
    self.v3 = round(self.v3, read32(stripe[:], 8))
    self.v4 = round(self.v4, read32(stripe[:], 12))
    at += 16
  }
  let rest : Array[Byte] = []
  for i in at..<buf.length() {
    rest.push(buf[i])
  }
  self.held = rest
}

///|
pub fn Xxh32::finish(self : Xxh32) -> UInt32 {
  let mut h = if self.total >= 16 {
    rotl(self.v1, 1) + rotl(self.v2, 7) + rotl(self.v3, 12) + rotl(self.v4, 18)
  } else {
    self.seed + prime5
  }
  h = h + self.total.reinterpret_as_uint()
  let held = Bytes::from_array(self.held)
  let data = held[:]
  let n = data.length()
  let mut at = 0
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
