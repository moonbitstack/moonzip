// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Compress into the LZ4 block format.
///
/// A block is a run of sequences. Each is a token whose high nibble is how many
/// literals follow and whose low nibble is the match length minus four, then the
/// literals, then a two-byte back-reference, then the match length's overflow
/// bytes. The last sequence carries literals only, and the format reserves the
/// last five bytes of the input for them — a decoder relies on both, which is
/// why `match_start` stops twelve bytes short of the end.
///
/// `level` picks the search depth: 0 uses one candidate per position, which is
/// what LZ4's own "fast" mode does; higher values walk a chain. The ratio gain
/// above the default is small and the cost is real — this is a format chosen for
/// speed.
pub fn lz4(data : BytesView, level~ : Int32 = 0) -> Bytes {
  let out : Array[Byte] = []
  let src = data.to_array()
  let n = src.length()
  // The format keeps the last five bytes as literals and requires every match to
  // start at least twelve bytes before the end.
  if n < 13 {
    write_last_literals(out, src, 0, n)
    return Bytes::from_array(out)
  }
  let mastart = n - 12
  let matches = if level <= 0 { 1 } else { level * 4 }
  let head = Array::make(1 << 14, -1)
  let prev = Array::make(n, -1)
  let mut ip = 0
  let mut anchor = 0
  while ip < mastart {
    let hash = hash4(src, ip)
    let mut candidate = head[hash]
    prev[ip] = candidate
    head[hash] = ip
    let mut best = 0
    let mut best_at = -1
    let mut left = matches
    while candidate >= 0 && left > 0 {
      let distance = ip - candidate
      if distance > 65535 {
        break
      }
      if src[candidate + best] == src[ip + best] &&
        word_at(src, candidate) == word_at(src, ip) {
        let mut len = 4
        while ip + len < mastart && src[candidate + len] == src[ip + len] {
          len += 1
        }
        if len > best {
          best = len
          best_at = candidate
          left = 0
          continue
        }
      }
      candidate = prev[candidate]
      left -= 1
    }
    if best_at < 0 {
      ip += 1
      continue
    }
    write_sequence(out, src, anchor, ip, ip - best_at, best)
    ip += best
    anchor = ip
  }
  write_last_literals(out, src, anchor, n)
  Bytes::from_array(out)
}

///|
/// Decompress an LZ4 block.
///
/// There is no length in the format, so `limit` is the only thing standing
/// between a hostile block and the heap.
pub fn unlz4(data : BytesView, limit? : Int32) -> Bytes raise @moonzip.Refused {
  let bound = match limit {
    Some(n) => n
    None => -1
  }
  let out : Array[Byte] = []
  let n = data.length()
  let mut at = 0
  while at < n {
    let token = data[at].to_int()
    at += 1
    let mut literals = token >> 4
    if literals == 15 {
      while true {
        guard at < n else { raise @moonzip.Truncated(at~) }
        let extra = data[at].to_int()
        at += 1
        literals += extra
        guard extra == 255 else { break }
      }
    }
    guard at + literals <= n else { raise @moonzip.Truncated(at~) }
    if bound >= 0 && out.length() + literals > bound {
      raise @moonzip.TooBig(limit=bound)
    }
    for i in 0..<literals {
      out.push(data[at + i])
    }
    at += literals
    // The last sequence is literals and nothing else: there is no offset after
    // it, because there is nothing left to refer back to.
    guard at < n else { break }
    guard at + 2 <= n else { raise @moonzip.Truncated(at~) }
    let distance = data[at].to_int() | (data[at + 1].to_int() << 8)
    at += 2
    guard distance > 0 && distance <= out.length() else {
      raise @moonzip.Distance(at~)
    }
    let mut length = token & 0x0F
    if length == 15 {
      while true {
        guard at < n else { raise @moonzip.Truncated(at~) }
        let extra = data[at].to_int()
        at += 1
        length += extra
        guard extra == 255 else { break }
      }
    }
    length += 4
    if bound >= 0 && out.length() + length > bound {
      raise @moonzip.TooBig(limit=bound)
    }
    let start = out.length() - distance
    for i in 0..<length {
      out.push(out[start + i])
    }
  }
  Bytes::from_array(out)
}

///|
fn word_at(src : Array[Byte], at : Int32) -> UInt32 {
  src[at].to_uint() |
  (src[at + 1].to_uint() << 8) |
  (src[at + 2].to_uint() << 16) |
  (src[at + 3].to_uint() << 24)
}

///|
fn hash4(src : Array[Byte], at : Int32) -> Int32 {
  ((word_at(src, at) * 2654435761U) >> 18).reinterpret_as_int()
}

///|
/// One token, its literals, the back-reference and the match.
fn write_sequence(
  out : Array[Byte],
  src : Array[Byte],
  anchor : Int32,
  ip : Int32,
  distance : Int32,
  length : Int32,
) -> Unit {
  let literals = ip - anchor
  let matched = length - 4
  let token = ((if literals >= 15 { 15 } else { literals }) << 4) |
    (if matched >= 15 { 15 } else { matched })
  out.push(token.to_byte())
  if literals >= 15 {
    write_tail(out, literals - 15)
  }
  for i in anchor..<ip {
    out.push(src[i])
  }
  out.push((distance & 0xFF).to_byte())
  out.push(((distance >> 8) & 0xFF).to_byte())
  if matched >= 15 {
    write_tail(out, matched - 15)
  }
}

///|
/// The bytes that carry a length past fifteen: as many 255s as fit, then the
/// remainder, which may be zero.
fn write_tail(out : Array[Byte], length : Int32) -> Unit {
  let mut left = length
  while left >= 255 {
    out.push(b'\xFF')
    left -= 255
  }
  out.push(left.to_byte())
}

///|
/// The final sequence: literals and no back-reference.
fn write_last_literals(
  out : Array[Byte],
  src : Array[Byte],
  anchor : Int32,
  n : Int32,
) -> Unit {
  let literals = n - anchor
  out.push(((if literals >= 15 { 15 } else { literals }) << 4).to_byte())
  if literals >= 15 {
    write_tail(out, literals - 15)
  }
  for i in anchor..<n {
    out.push(src[i])
  }
}
