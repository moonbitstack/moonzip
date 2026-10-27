// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The magic: `7z\xBC\xAF\x27\x1C`. The last four bytes were chosen as a check so
/// that a truncated or byte-swapped file fails on the first six bytes rather than
/// three levels into the header.
let magic : FixedArray[Int32] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]

///|
/// The header's property ids, in the order the specification lists them.
///
/// They are not zero-based or grouped — `kName` is seventeen and `kMTime` twenty —
/// because the format grew: ids were taken as needs appeared, and the gaps are
/// what that looks like.
let k_end : Int32 = 0x00

///|
let k_header : Int32 = 0x01

///|
let k_archive_properties : Int32 = 0x02

///|
let k_additional_streams : Int32 = 0x03

///|
let k_main_streams : Int32 = 0x04

///|
let k_files_info : Int32 = 0x05

///|
let k_pack_info : Int32 = 0x06

///|
let k_unpack_info : Int32 = 0x07

///|
let k_substreams_info : Int32 = 0x08

///|
let k_size : Int32 = 0x09

///|
let k_crc : Int32 = 0x0A

///|
let k_folder : Int32 = 0x0B

///|
let k_coders_unpack_size : Int32 = 0x0C

///|
let k_num_unpack_stream : Int32 = 0x0D

///|
let k_empty_stream : Int32 = 0x0E

///|
let k_empty_file : Int32 = 0x0F

///|
let k_anti : Int32 = 0x10

///|
let k_name : Int32 = 0x11
// 0x12 (creation time), 0x13 (access time), 0x16 (comment) and 0x18 (start
// position) are defined and never written by anything modern; a reader steps
// over them by their declared length rather than pretending to understand them.

///|
let k_mtime : Int32 = 0x14

///|
let k_attributes : Int32 = 0x15

///|
let k_encoded_header : Int32 = 0x17

///|
let k_dummy : Int32 = 0x19

///|
/// A cursor over the header bytes.
///
/// Every read is bounds-checked into `Truncated` rather than a panic, because a
/// header is the part of an archive an attacker gets to choose.
priv struct Cursor {
  data : BytesView
  mut at : Int32
}

///|
fn Cursor::new(data : BytesView) -> Cursor {
  { data, at: 0, }
}

///|
fn Cursor::left(self : Cursor) -> Int32 {
  self.data.length() - self.at
}

///|
fn Cursor::byte(self : Cursor) -> Int32 raise @moonzip.Refused {
  if self.at >= self.data.length() {
    raise @moonzip.Truncated(at=self.at)
  }
  let value = self.data[self.at].to_int()
  self.at += 1
  value
}

///|
fn Cursor::peek(self : Cursor) -> Int32 raise @moonzip.Refused {
  if self.at >= self.data.length() {
    raise @moonzip.Truncated(at=self.at)
  }
  self.data[self.at].to_int()
}

///|
fn Cursor::take(self : Cursor, n : Int32) -> BytesView raise @moonzip.Refused {
  if n < 0 || self.left() < n {
    raise @moonzip.Truncated(at=self.at)
  }
  let slice = self.data[self.at:self.at + n]
  self.at += n
  slice
}

///|
/// A variable-length integer.
///
/// The first byte says how many follow, by counting its leading one bits: seven
/// payload bits with no continuation, six with one byte after, and so on until
/// `1111_1111`, which means "eight bytes follow, plainly". It is not how most
/// formats write a length, and it is why a header of twelve entries can still be
/// nine bytes long.
fn Cursor::uint64(self : Cursor) -> Int64 raise @moonzip.Refused {
  let first = self.byte()
  let mut extra = 0
  let mut bit = 0x80
  while (first & bit) != 0 {
    extra += 1
    if extra == 8 {
      break
    }
    bit = bit >> 1
  }
  if extra == 8 {
    return self.u64le()
  }
  // The first byte holds the *high* bits: `10xxxxxx` with one byte after it is
  // `xxxxxx << 8 | y`, not `xxxxxx | y << 16`. Reading it the other way is a
  // factor of 256 out and only shows up as an unpacked size that nothing can
  // produce.
  let high = (first & ((1 << (7 - extra)) - 1)).to_int64()
  let mut low = 0L
  for i in 0..<extra {
    low = low | (self.byte().to_int64() << (i * 8))
  }
  (high << (extra * 8)) | low
}

///|
fn Cursor::u32le(self : Cursor) -> UInt32 raise @moonzip.Refused {
  let mut value = 0U
  for i in 0..<4 {
    value = value | (self.byte().reinterpret_as_uint() << (i * 8))
  }
  value
}

///|
fn Cursor::u64le(self : Cursor) -> Int64 raise @moonzip.Refused {
  let mut value = 0L
  for i in 0..<8 {
    value = value | (self.byte().to_int64() << (i * 8))
  }
  value
}

///|
/// A bit vector, most significant bit first.
///
/// `check_all` is for the properties that begin with an "all defined" byte — a
/// writer that defines every entry writes one byte instead of the vector, and a
/// reader has to look.
fn Cursor::booleans(
  self : Cursor,
  count : Int32,
  check_all : Bool,
) -> Array[Bool] raise @moonzip.Refused {
  let out = Array::make(count, false)
  if check_all && self.byte() != 0 {
    for i in 0..<count {
      out[i] = true
    }
    return out
  }
  let mut current = 0
  let mut mask = 0
  for i in 0..<count {
    if mask == 0 {
      current = self.byte()
      mask = 0x80
    }
    out[i] = (current & mask) != 0
    mask = mask >> 1
  }
  out
}

///|
/// A NUL-terminated UTF-16LE string. Names are the one place the format is not
/// length-prefixed, so a truncated archive shows up as a name that runs into the
/// next property.
fn Cursor::utf16(self : Cursor) -> String raise @moonzip.Refused {
  let bytes : Array[Byte] = []
  while true {
    let low = self.byte()
    let high = self.byte()
    if low == 0 && high == 0 {
      break
    }
    // Everything above the basic plane arrives as a surrogate pair, which is two
    // of these in a row; them being left alone is why a name with an emoji
    // survives a round trip.
    bytes.push(low.to_byte())
    bytes.push(high.to_byte())
  }
  @utf16.decode_lossy(Bytes::from_array(bytes)[:])
}

// ------------------------------------------------------------------- the writer's half

///|
/// A growable byte sink for the header. The header is small and its size is only
/// known after it is built, which is why this is an array and not a preallocation.
priv struct Put {
  out : Array[Byte]
}

///|
fn Put::new() -> Put {
  { out: [], }
}

///|
fn Put::byte(self : Put, value : Int32) -> Unit {
  self.out.push(value.to_byte())
}

///|
fn Put::bytes(self : Put, data : BytesView) -> Unit {
  for b in data {
    self.out.push(b)
  }
}

///|
fn Put::u32le(self : Put, value : UInt32) -> Unit {
  for i in 0..<4 {
    self.byte(((value >> (i * 8)) & 0xFFU).reinterpret_as_int())
  }
}

///|
fn Put::u64le(self : Put, value : Int64) -> Unit {
  for i in 0..<8 {
    self.byte(((value >> (i * 8)) & 0xFFL).to_int())
  }
}

///|
/// The variable-length integer, written as the reader expects to find it.
fn Put::uint64(self : Put, value : Int64) -> Unit {
  if value < 0x80L {
    self.byte(value.to_int())
    return
  }
  if value > 0xFFFFFFFFFFFFFFL {
    self.byte(0xFF)
    self.u64le(value)
    return
  }
  // A form of `n` bytes holds `7n` bits: the first byte keeps `8 - n` payload
  // bits after its `n - 1` ones, and the bytes after it add `8(n - 1)`. Getting
  // this bound wrong does not corrupt small values — it starts at 16384, which is
  // exactly the size a test with a small body never reaches.
  let mut length = 1
  while length < 8 && value >= 1L << (7 * length) {
    length += 1
  }
  if length == 8 {
    self.byte(0xFF)
    self.u64le(value)
    return
  }
  let tail_bits = 8 * (length - 1)
  let tail = value & ((1L << tail_bits) - 1L)
  let head = (value >> tail_bits).to_int()
  let prefix = (0xFF << (9 - length)) & 0xFF
  self.byte(prefix | (head & ((1 << (8 - length)) - 1)))
  for i in 0..<(length - 1) {
    self.byte(((tail >> (i * 8)) & 0xFFL).to_int())
  }
}

///|
fn Put::booleans(self : Put, flags : Array[Bool], check_all : Bool) -> Unit {
  if check_all {
    let mut all = true
    for f in flags {
      if !f {
        all = false
      }
    }
    if all {
      self.byte(1)
      return
    }
    self.byte(0)
  }
  let mut current = 0
  let mut mask = 0x80
  for f in flags {
    if f {
      current = current | mask
    }
    mask = mask >> 1
    if mask == 0 {
      self.byte(current)
      current = 0
      mask = 0x80
    }
  }
  if mask != 0x80 {
    self.byte(current)
  }
}

///|
fn Put::utf16(self : Put, text : String) -> Unit {
  let encoded = @utf16.encode(text)
  for b in encoded {
    self.out.push(b)
  }
  self.byte(0)
  self.byte(0)
}

///|
fn Put::finish(self : Put) -> Bytes {
  Bytes::from_array(self.out)
}
