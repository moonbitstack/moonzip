// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Compress into one fixed-Huffman DEFLATE block.
///
/// LZ77 finds back-references with a hash chain over a 32 KiB window, capped so
/// the search stays linear in the input. The fixed code table is used rather
/// than a dynamic one because a dynamic block must carry its own code lengths,
/// which costs more than it saves on the short bodies a response compressor
/// sees — and because the reader below takes either.
pub fn deflate(data : BytesView) -> Bytes {
  let bw = { out: [], acc: 0, held: 0, }
  bw.bits(1, 1) // BFINAL: this is the only block
  bw.bits(1, 2) // BTYPE 01: fixed Huffman codes
  let n = data.length()
  if n > 0 {
    let head = Array::make(1 << 15, -1)
    let prev = Array::make(n, -1)
    let mut i = 0
    while i < n {
      let mut best_len = 0
      let mut best_dist = 0
      if i + min_match <= n {
        let cap = if n - i < max_match { n - i } else { max_match }
        let mut j = head[hash3(data, i)]
        let mut chain = max_chain
        while j >= 0 && chain > 0 {
          let dist = i - j
          if dist > window {
            break
          }
          let mut len = 0
          while len < cap && data[j + len] == data[i + len] {
            len += 1
          }
          if len > best_len {
            best_len = len
            best_dist = dist
            if len >= cap {
              break
            }
          }
          j = prev[j]
          chain -= 1
        }
      }
      let taken = if best_len >= min_match {
        emit_match(bw, best_len, best_dist)
        best_len
      } else {
        emit(bw, data[i].to_int())
        1
      }
      // Every position inside a match still goes into the chain, or the next
      // match cannot start in the middle of this one.
      for _ in 0..<taken {
        if i + min_match <= n {
          let h = hash3(data, i)
          prev[i] = head[h]
          head[h] = i
        }
        i += 1
      }
    }
  }
  emit(bw, 256) // end of block
  bw.finish()
}

///|
/// Decompress a raw DEFLATE stream.
///
/// All three block types: stored, fixed Huffman, and the dynamic Huffman blocks
/// that carry their own code tables — which is what zlib, gzip and every browser
/// actually emit, so a reader without them reads almost nothing.
pub fn inflate(data : BytesView) -> Bytes raise @moonzip.Broken {
  let br = { src: data, pos: 0, acc: 0, held: 0, }
  let out : Array[Byte] = []
  let mut last = false
  while !last {
    last = br.bits(1) == 1
    match br.bits(2) {
      0 => stored(br, out)
      1 => block(br, out, fixed_litlen, fixed_dist)
      2 => {
        let (litlen, dist) = tables(br)
        block(br, out, litlen, dist)
      }
      _ =>
        raise @moonzip.Header(
          at=br.pos,
          what="a block type DEFLATE does not define",
        )
    }
  }
  Bytes::from_array(out)
}

// ------------------------------------------------------------------ the codes

///|
/// The base length for each length symbol 257–285 (RFC 1951 §3.2.5).
let length_base : FixedArray[Int] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
  99, 115, 131, 163, 195, 227, 258,
]

///|
let length_extra : FixedArray[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5,
  5, 0,
]

///|
/// The base distance for each distance symbol 0–29.
let dist_base : FixedArray[Int] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]

///|
let dist_extra : FixedArray[Int] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
  12, 12, 13, 13,
]

///|
/// The order the code-length code's own lengths are written in (§3.2.7), which
/// puts the lengths most likely to be zero last so they can be left out.
let length_order : FixedArray[Int] = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
]

///|
let min_match : Int = 3

///|
let max_match : Int = 258

///|
let window : Int = 32768

///|
let max_chain : Int = 256

///|
/// The length symbol for a match length, with its extra bits and their value.
fn length_code(len : Int) -> (Int, Int, Int) {
  let mut i = 28
  while i > 0 && length_base[i] > len {
    i -= 1
  }
  (257 + i, length_extra[i], len - length_base[i])
}

///|
fn distance_code(dist : Int) -> (Int, Int, Int) {
  let mut i = 29
  while i > 0 && dist_base[i] > dist {
    i -= 1
  }
  (i, dist_extra[i], dist - dist_base[i])
}

///|
/// The fixed literal/length code of §3.2.6, as a code and a width.
fn fixed_code(sym : Int) -> (Int, Int) {
  if sym < 144 {
    (0x30 + sym, 8)
  } else if sym < 256 {
    (0x190 + (sym - 144), 9)
  } else if sym < 280 {
    (sym - 256, 7)
  } else {
    (0xC0 + (sym - 280), 8)
  }
}

// ---------------------------------------------------------------- the encoder

///|
priv struct Writer {
  out : Array[Byte]
  mut acc : Int
  mut held : Int
}

///|
/// The low `count` bits of `value`, least significant first — DEFLATE's own bit
/// order for headers and extra bits.
fn Writer::bits(self : Writer, value : Int, count : Int) -> Unit {
  self.acc = self.acc | ((value & ((1 << count) - 1)) << self.held)
  self.held += count
  while self.held >= 8 {
    self.out.push((self.acc & 0xFF).to_byte())
    self.acc = self.acc >> 8
    self.held -= 8
  }
}

///|
/// A Huffman code goes out most significant bit first, against the stream's own
/// order — so it is reversed on the way in (§3.1.1).
fn Writer::huff(self : Writer, code : Int, len : Int) -> Unit {
  let mut flipped = 0
  for i in 0..<len {
    flipped = (flipped << 1) | ((code >> i) & 1)
  }
  self.bits(flipped, len)
}

///|
fn Writer::finish(self : Writer) -> Bytes {
  if self.held > 0 {
    self.out.push((self.acc & 0xFF).to_byte())
    self.acc = 0
    self.held = 0
  }
  Bytes::from_array(self.out)
}

///|
fn emit(bw : Writer, sym : Int) -> Unit {
  let (code, len) = fixed_code(sym)
  bw.huff(code, len)
}

///|
fn emit_match(bw : Writer, len : Int, dist : Int) -> Unit {
  let (lsym, lext, lval) = length_code(len)
  emit(bw, lsym)
  if lext > 0 {
    bw.bits(lval, lext)
  }
  let (dsym, dext, dval) = distance_code(dist)
  // In a fixed block every distance code is five bits wide.
  bw.huff(dsym, 5)
  if dext > 0 {
    bw.bits(dval, dext)
  }
}

///|
/// Three bytes folded into a chain bucket.
fn hash3(data : BytesView, i : Int) -> Int {
  (
    (data[i].to_int() << 10) ^
    (data[i + 1].to_int() << 5) ^
    data[i + 2].to_int()
  ) &
  0x7FFF
}

// ---------------------------------------------------------------- the decoder

///|
priv struct Reader {
  src : BytesView
  mut pos : Int
  mut acc : Int
  mut held : Int
}

///|
fn Reader::bits(self : Reader, count : Int) -> Int raise @moonzip.Broken {
  while self.held < count {
    if self.pos >= self.src.length() {
      raise @moonzip.Truncated(at=self.pos)
    }
    self.acc = self.acc | (self.src[self.pos].to_int() << self.held)
    self.pos += 1
    self.held += 8
  }
  let value = self.acc & ((1 << count) - 1)
  self.acc = self.acc >> count
  self.held -= count
  value
}

///|
/// A canonical Huffman code, held as the count of codes at each width and the
/// symbols in code order — which is all a bit-at-a-time decoder needs, and a
/// great deal less than a table (RFC 1951 §3.2.2).
priv struct Huffman {
  counts : FixedArray[Int]
  symbols : FixedArray[Int]
}

///|
/// Build a code from the width assigned to each symbol. A width of zero means
/// the symbol is not in the code.
fn Huffman::of(lengths : FixedArray[Int], n : Int) -> Huffman {
  let counts = FixedArray::make(16, 0)
  for i in 0..<n {
    counts[lengths[i]] += 1
  }
  counts[0] = 0
  let offsets = FixedArray::make(16, 0)
  for width in 1..<16 {
    offsets[width] = offsets[width - 1] + counts[width - 1]
  }
  let symbols = FixedArray::make(if n > 0 { n } else { 1 }, 0)
  for i in 0..<n {
    if lengths[i] != 0 {
      symbols[offsets[lengths[i]]] = i
      offsets[lengths[i]] += 1
    }
  }
  { counts, symbols, }
}

///|
/// Read one symbol, a bit at a time.
///
/// Codes of a given width are consecutive integers, and widths are assigned
/// shortest first, so "is this code one of the ones at this width" is a
/// subtraction — no table to build and no way for a malformed length list to
/// index out of one.
fn Huffman::read(self : Huffman, br : Reader) -> Int raise @moonzip.Broken {
  let mut code = 0
  let mut first = 0
  let mut index = 0
  for width in 1..<16 {
    code = code | br.bits(1)
    let count = self.counts[width]
    if code - first < count {
      return self.symbols[index + (code - first)]
    }
    index += count
    first = (first + count) << 1
    code = code << 1
  }
  raise @moonzip.Code(at=br.pos)
}

///|
let fixed_litlen : Huffman = {
  let lengths = FixedArray::make(288, 8)
  for i in 144..<256 {
    lengths[i] = 9
  }
  for i in 256..<280 {
    lengths[i] = 7
  }
  Huffman::of(lengths, 288)
}

///|
let fixed_dist : Huffman = Huffman::of(FixedArray::make(30, 5), 30)

///|
/// A stored block: the bit stream aligns to a byte, then a length, its
/// complement, and that many bytes verbatim (§3.2.4).
fn stored(br : Reader, out : Array[Byte]) -> Unit raise @moonzip.Broken {
  br.acc = 0
  br.held = 0
  if br.pos + 4 > br.src.length() {
    raise @moonzip.Truncated(at=br.pos)
  }
  let len = br.src[br.pos].to_int() | (br.src[br.pos + 1].to_int() << 8)
  let nlen = br.src[br.pos + 2].to_int() | (br.src[br.pos + 3].to_int() << 8)
  if len != (nlen ^ 0xFFFF) {
    raise @moonzip.Header(
      at=br.pos,
      what="a stored block's length and its complement disagree",
    )
  }
  br.pos += 4
  if br.pos + len > br.src.length() {
    raise @moonzip.Truncated(at=br.pos)
  }
  for _ in 0..<len {
    out.push(br.src[br.pos])
    br.pos += 1
  }
}

///|
/// The code tables a dynamic block carries with it (§3.2.7).
fn tables(br : Reader) -> (Huffman, Huffman) raise @moonzip.Broken {
  let nlit = br.bits(5) + 257
  let ndist = br.bits(5) + 1
  let ncode = br.bits(4) + 4
  let meta = FixedArray::make(19, 0)
  for i in 0..<ncode {
    meta[length_order[i]] = br.bits(3)
  }
  let code_lengths = Huffman::of(meta, 19)
  let lengths = FixedArray::make(nlit + ndist, 0)
  let mut i = 0
  while i < nlit + ndist {
    let sym = code_lengths.read(br)
    if sym < 16 {
      lengths[i] = sym
      i += 1
    } else {
      let (repeat, value) = match sym {
        16 => {
          if i == 0 {
            raise @moonzip.Code(at=br.pos)
          }
          (3 + br.bits(2), lengths[i - 1])
        }
        17 => (3 + br.bits(3), 0)
        _ => (11 + br.bits(7), 0)
      }
      if i + repeat > nlit + ndist {
        raise @moonzip.Code(at=br.pos)
      }
      for _ in 0..<repeat {
        lengths[i] = value
        i += 1
      }
    }
  }
  let lit = FixedArray::make(nlit, 0)
  for k in 0..<nlit {
    lit[k] = lengths[k]
  }
  let dist = FixedArray::make(ndist, 0)
  for k in 0..<ndist {
    dist[k] = lengths[nlit + k]
  }
  (Huffman::of(lit, nlit), Huffman::of(dist, ndist))
}

///|
/// The body of a compressed block, under whichever pair of code tables.
fn block(
  br : Reader,
  out : Array[Byte],
  litlen : Huffman,
  dist : Huffman,
) -> Unit raise @moonzip.Broken {
  let mut open = true
  while open {
    let sym = litlen.read(br)
    if sym < 256 {
      out.push(sym.to_byte())
    } else if sym == 256 {
      open = false
    } else {
      let index = sym - 257
      if index >= 29 {
        raise @moonzip.Code(at=br.pos)
      }
      let len = length_base[index] + br.bits(length_extra[index])
      let dcode = dist.read(br)
      if dcode >= 30 {
        raise @moonzip.Code(at=br.pos)
      }
      let back = dist_base[dcode] + br.bits(dist_extra[dcode])
      if back > out.length() {
        raise @moonzip.Distance(at=br.pos)
      }
      // Copied a byte at a time on purpose: a run-length match overlaps itself,
      // and the bytes it copies are the ones this loop is writing.
      let start = out.length() - back
      for k in 0..<len {
        out.push(out[start + k])
      }
    }
  }
}
