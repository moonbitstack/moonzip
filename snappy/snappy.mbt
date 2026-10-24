// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Compress into the Snappy block format.
///
/// A block starts with the uncompressed length as a varint — the one thing a
/// decoder is told up front, and the reason Snappy needs no bound of its own to
/// be safe — and then a run of tags. A tag is a literal or a copy, and its two
/// low bits say which: `00` a literal, `01` a copy with an eleven-bit offset,
/// `10` one with a sixteen-bit offset, `11` one with a thirty-two-bit offset.
/// The three copy forms exist so that the common cases cost two bytes.
///
/// The compressor is greedy: one candidate per position from a hash of four
/// bytes, extended as far as it runs. Snappy's own encoder is not much cleverer,
/// because the format's whole point is that decompression be quick.
pub fn snappy(data : BytesView) -> Bytes {
  let out : Array[Byte] = []
  varint(out, data.length())
  let src = data.to_array()
  let n = src.length()
  let head = Array::make(1 << 14, -1)
  let prev = Array::make(if n > 0 { n } else { 1 }, -1)
  let mut ip = 0
  let mut anchor = 0
  while ip + 4 <= n {
    let hash = hash4(src, ip)
    let candidate = head[hash]
    prev[ip] = candidate
    head[hash] = ip
    if candidate >= 0 &&
      ip - candidate <= 65535 &&
      word_at(src, candidate) == word_at(src, ip) {
      write_literals(out, src, anchor, ip)
      let mut length = 4
      while ip + length < n && src[candidate + length] == src[ip + length] {
        length += 1
      }
      write_copy(out, ip - candidate, length)
      // Every position inside a copy still goes into the table, or the next
      // match could not start in the middle of this one.
      for step in 1..<length {
        if ip + step + 4 <= n {
          let index = ip + step
          let h = hash4(src, index)
          prev[index] = head[h]
          head[h] = index
        }
      }
      ip += length
      anchor = ip
    } else {
      ip += 1
    }
  }
  write_literals(out, src, anchor, n)
  Bytes::from_array(out)
}

///|
/// Decompress a Snappy block.
///
/// The length in front is a claim, not a fact, so `limit` still applies: a
/// sixteen-byte block can claim four gigabytes. The claim is also what lets this
/// reader refuse a stream that ends early rather than return what it got.
pub fn unsnappy(
  data : BytesView,
  limit? : Int32,
) -> Bytes raise @moonzip.Refused {
  let mut at = 0
  let claimed = match read_varint(data, at) {
    Some(pair) => {
      at = pair.1
      pair.0
    }
    None => raise @moonzip.Truncated(at=0)
  }
  let bound = match limit {
    Some(n) => if n < claimed { n } else { claimed }
    None => claimed
  }
  let out : Array[Byte] = []
  let n = data.length()
  while at < n {
    let tag = data[at].to_int()
    at += 1
    let kind = tag & 0x03
    if kind == 0 {
      let mut length = tag >> 2
      if length < 60 {
        length += 1
      } else {
        // Sixty or more means the length is in the next one to four bytes,
        // little-endian, biased by one.
        let bytes = length - 59
        guard at + bytes <= n else { raise @moonzip.Truncated(at~) }
        let mut wide = 0
        for i in 0..<bytes {
          wide = wide | (data[at + i].to_int() << (i * 8))
        }
        at += bytes
        length = wide + 1
      }
      guard at + length <= n else { raise @moonzip.Truncated(at~) }
      if out.length() + length > bound {
        raise @moonzip.TooBig(limit=bound)
      }
      for i in 0..<length {
        out.push(data[at + i])
      }
      at += length
    } else {
      let (distance, length) = match kind {
        1 => {
          guard at + 1 <= n else { raise @moonzip.Truncated(at~) }
          let distance = (tag >> 5 << 8) | data[at].to_int()
          at += 1
          (distance, 4 + ((tag >> 2) & 0x07))
        }
        2 => {
          guard at + 2 <= n else { raise @moonzip.Truncated(at~) }
          let distance = data[at].to_int() | (data[at + 1].to_int() << 8)
          at += 2
          (distance, 1 + (tag >> 2))
        }
        _ => {
          guard at + 4 <= n else { raise @moonzip.Truncated(at~) }
          let distance = data[at].to_int() |
            (data[at + 1].to_int() << 8) |
            (data[at + 2].to_int() << 16) |
            (data[at + 3].to_int() << 24)
          at += 4
          (distance, 1 + (tag >> 2))
        }
      }
      guard distance > 0 && distance <= out.length() else {
        raise @moonzip.Distance(at~)
      }
      if out.length() + length > bound {
        raise @moonzip.TooBig(limit=bound)
      }
      let start = out.length() - distance
      for i in 0..<length {
        out.push(out[start + i])
      }
    }
  }
  guard out.length() == claimed else { raise @moonzip.Truncated(at=n) }
  Bytes::from_array(out)
}

// ------------------------------------------------------------------- the tags

///|
/// A little-endian base-128 integer: seven bits a byte, the top bit meaning
/// "another byte follows".
fn varint(out : Array[Byte], value : Int32) -> Unit {
  let mut left = value
  while left >= 0x80 {
    out.push(((left & 0x7F) | 0x80).to_byte())
    left = left >> 7
  }
  out.push(left.to_byte())
}

///|
fn read_varint(data : BytesView, from : Int32) -> (Int32, Int32)? {
  let mut value = 0
  let mut shift = 0
  let mut at = from
  while at < data.length() && shift <= 28 {
    let byte = data[at].to_int()
    at += 1
    value = value | ((byte & 0x7F) << shift)
    if (byte & 0x80) == 0 {
      return Some((value, at))
    }
    shift += 7
  }
  None
}

///|
/// Literals: one tag and, when they are long, the length in one to four bytes.
fn write_literals(
  out : Array[Byte],
  src : Array[Byte],
  from : Int32,
  to : Int32,
) -> Unit {
  let length = to - from
  if length == 0 {
    return
  }
  let biased = length - 1
  if biased < 60 {
    out.push((biased << 2).to_byte())
  } else {
    let mut bytes = 1
    while bytes < 4 && biased >> (bytes * 8) != 0 {
      bytes += 1
    }
    out.push(((59 + bytes) << 2).to_byte())
    for i in 0..<bytes {
      out.push(((biased >> (i * 8)) & 0xFF).to_byte())
    }
  }
  for i in from..<to {
    out.push(src[i])
  }
}

///|
/// A copy, in the cheapest of the three forms that can hold it: eleven-bit offset
/// and four to eleven bytes, then sixteen-bit offset and up to sixty-four, then
/// the wide form. A match longer than sixty-four bytes is several copies, which
/// costs a byte each and keeps the decoder simple — which is the whole point of
/// the format.
fn write_copy(out : Array[Byte], distance : Int32, length : Int32) -> Unit {
  let mut left = length
  while left > 0 {
    if left >= 4 && left <= 11 && distance < 2048 {
      out.push(((distance >> 8 << 5) | ((left - 4) << 2) | 1).to_byte())
      out.push((distance & 0xFF).to_byte())
      left = 0
    } else {
      let take = if left > 64 { 64 } else { left }
      if distance < 65536 {
        out.push((((take - 1) << 2) | 2).to_byte())
        out.push((distance & 0xFF).to_byte())
        out.push(((distance >> 8) & 0xFF).to_byte())
      } else {
        out.push((((take - 1) << 2) | 3).to_byte())
        for i in 0..<4 {
          out.push(((distance >> (i * 8)) & 0xFF).to_byte())
        }
      }
      left -= take
    }
  }
}

///|
fn word_at(src : Array[Byte], at : Int32) -> Int32 {
  src[at].to_int() |
  (src[at + 1].to_int() << 8) |
  (src[at + 2].to_int() << 16) |
  (src[at + 3].to_int() << 24)
}

///|
fn hash4(src : Array[Byte], at : Int32) -> Int32 {
  ((word_at(src, at).reinterpret_as_uint() * 0x9E3779B1U) >> 18).reinterpret_as_int()
}
