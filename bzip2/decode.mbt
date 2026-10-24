// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A field that has to be there, or the stream is short.
///
/// Running out of bytes is reported as `Truncated` rather than as a private
/// error, because a decoder being fed a stream a piece at a time cannot tell the
/// two apart — and should not pretend to. The reader keeps its position and asks
/// again when it has more; the one-shot reader passes the error on.
fn need(bits : Bits, n : Int32) -> Int32 raise @moonzip.Refused {
  match bits.take(n) {
    Some(value) => value
    None => raise @moonzip.Truncated(at=bits.used())
  }
}

///|
/// The three arrays `BZ2_hbCreateDecodeTables` builds, and nothing else.
///
/// bzip2 sends code *lengths* and derives the codes, so the decoder's table is
/// three integers per length band: where the symbols of that length start, the
/// highest code of that length, and the symbols themselves in canonical order.
/// Decoding is then a loop that reads one bit at a time until the code fits under
/// `limit` — no lookup table, because there is no byte alignment to build one
/// against.
priv struct Codes {
  perm : Array[Int32]
  base : Array[Int32]
  limit : Array[Int32]
  min_len : Int32
}

///|
fn Codes::build(lengths : Array[Int32], alpha : Int32) -> Codes {
  let mut min_len = 32
  let mut max_len = 0
  for i in 0..<alpha {
    if lengths[i] > max_len {
      max_len = lengths[i]
    }
    if lengths[i] < min_len {
      min_len = lengths[i]
    }
  }
  let perm : Array[Int32] = []
  for len in min_len..<=max_len {
    for symbol in 0..<alpha {
      if lengths[symbol] == len {
        perm.push(symbol)
      }
    }
  }
  // One more slot than the longest code, because `base[length + 1]` is written
  // before the prefix sum runs and the last length needs a slot to overflow into.
  let base = Array::make(24, 0)
  let limit = Array::make(24, 0)
  for i in 0..<alpha {
    base[lengths[i] + 1] += 1
  }
  for i in 1..<24 {
    base[i] += base[i - 1]
  }
  let mut vec = 0
  for i in min_len..<=max_len {
    vec += base[i + 1] - base[i]
    limit[i] = vec - 1
    vec = vec << 1
  }
  for i in (min_len + 1)..<=max_len {
    base[i] = ((limit[i - 1] + 1) << 1) - base[i]
  }
  { perm, base, limit, min_len, }
}

///|
fn Codes::read(self : Codes, bits : Bits) -> Int32 raise @moonzip.Refused {
  let mut len = self.min_len
  let mut code = need(bits, len)
  while code > self.limit[len] {
    len += 1
    if len > 20 {
      // Twenty is the longest code the format allows, so anything past it is a
      // table that does not add up rather than a stream that ends here.
      return -1
    }
    code = (code << 1) | need(bits, 1)
  }
  let at = code - self.base[len]
  if at < 0 || at >= self.perm.length() {
    return -1
  }
  self.perm[at]
}

///|
/// Which table the next symbol comes from.
///
/// A selector covers fifty symbols, and the table changes when the count runs
/// out rather than when a byte is produced — counting bytes here is the mistake
/// that decodes the first fifty symbols correctly and everything after them as
/// noise.
priv struct Fetcher {
  tables : Array[Codes]
  selectors : Array[Int32]
  mut group_no : Int32
  mut group_pos : Int32
  mut group : Int32
}

///|
fn Fetcher::new(tables : Array[Codes], selectors : Array[Int32]) -> Fetcher {
  { tables, selectors, group_no: -1, group_pos: 0, group: 0, }
}

///|
fn Fetcher::next(self : Fetcher, bits : Bits) -> Int32 raise @moonzip.Refused {
  if self.group_pos == 0 {
    self.group_no += 1
    if self.group_no >= self.selectors.length() {
      // The block said how many selectors it has; running past them is a table
      // that does not describe the data, not a stream that ends here.
      raise @moonzip.Code(at=bits.used())
    }
    self.group_pos = 50
    self.group = self.selectors[self.group_no]
  }
  self.group_pos -= 1
  self.tables[self.group].read(bits)
}

///|
/// One block, after its six magic bytes.
///
/// The five stages in order, which is the format: the header, the Huffman
/// tables, the move-to-front symbols with runs collapsed, the inverse
/// Burrows-Wheeler, and then the run-length stage the sort was fed from. The CRC
/// is checked at the end against the one in the header, because it is over the
/// bytes after the last stage.
fn read_block(
  bits : Bits,
  level : Int32,
) -> (Bytes, UInt32) raise @moonzip.Refused {
  let want_crc = match bits.take_word() {
    Some(v) => v
    None => raise @moonzip.Truncated(at=bits.used())
  }
  let randomised = need(bits, 1) != 0
  let orig_ptr = need(bits, 24)
  let max_block = 100000 * level
  if orig_ptr < 0 || orig_ptr > max_block + 10 {
    raise @moonzip.Header(
      at=bits.used(),
      what="the block's start pointer is outside the block",
    )
  }
  // Which bytes appear at all: a sixteen-bit bitmap of sixteen-bit bitmaps.
  let map = need(bits, 16)
  let present = Array::make(256, false)
  for group in 0..<16 {
    if ((map >> (15 - group)) & 1) == 1 {
      let group_map = need(bits, 16)
      for k in 0..<16 {
        if ((group_map >> (15 - k)) & 1) == 1 {
          present[group * 16 + k] = true
        }
      }
    }
  }
  let seq_to_unseq : Array[Int32] = []
  let unseq_to_seq = Array::make(256, -1)
  for byte in 0..<256 {
    if present[byte] {
      unseq_to_seq[byte] = seq_to_unseq.length()
      seq_to_unseq.push(byte)
    }
  }
  let n_in_use = seq_to_unseq.length()
  if n_in_use == 0 {
    raise @moonzip.Header(
      at=bits.used(),
      what="a block that uses no bytes at all",
    )
  }
  let alpha = n_in_use + 2
  let eob = n_in_use + 1
  let n_groups = need(bits, 3)
  if n_groups < 2 || n_groups > 6 {
    raise @moonzip.Header(
      at=bits.used(),
      what="a block with the wrong number of code tables",
    )
  }
  // Fifteen bits, not a unary count. This is the field that cost the most time to
  // get right: a unary reading decodes the first table and then walks off into
  // the data.
  let n_selectors = need(bits, 15)
  if n_selectors < 1 {
    raise @moonzip.Header(at=bits.used(), what="a block with no selectors")
  }
  let selector_mtf = Array::make(n_selectors, 0)
  for i in 0..<n_selectors {
    let mut j = 0
    while need(bits, 1) == 1 {
      j += 1
      if j >= n_groups {
        raise @moonzip.Code(at=bits.used())
      }
    }
    selector_mtf[i] = j
  }
  let selectors = Array::make(n_selectors, 0)
  let order = Array::make(n_groups, 0)
  for i in 0..<n_groups {
    order[i] = i
  }
  for i in 0..<n_selectors {
    let mut v = selector_mtf[i]
    let moved = order[v]
    while v > 0 {
      order[v] = order[v - 1]
      v -= 1
    }
    order[0] = moved
    selectors[i] = moved
  }
  // Code lengths, delta-coded: one bit per symbol to say "same as the last one"
  // and two to say which way it moved.
  let lengths = Array::make(n_groups * alpha, 0)
  for group in 0..<n_groups {
    let cur = need(bits, 5)
    let mut curr = cur
    for symbol in 0..<alpha {
      while true {
        if curr < 1 || curr > 20 {
          raise @moonzip.Code(at=bits.used())
        }
        if need(bits, 1) == 0 {
          break
        }
        if need(bits, 1) == 0 {
          curr += 1
        } else {
          curr -= 1
        }
      }
      lengths[group * alpha + symbol] = curr
    }
  }
  let tables : Array[Codes] = []
  for group in 0..<n_groups {
    let row : Array[Int32] = []
    for symbol in 0..<alpha {
      row.push(lengths[group * alpha + symbol])
    }
    tables.push(Codes::build(row, alpha))
  }
  // The move-to-front symbols, with runs of "the byte at the front" collapsed
  // into a binary count.
  let mtf : Array[Int32] = []
  for i in 0..<n_in_use {
    mtf.push(i)
  }
  let block : Array[Int32] = []
  let fetcher = Fetcher::new(tables, selectors)
  let mut sym = fetcher.next(bits)
  while true {
    if sym < 0 {
      raise @moonzip.Code(at=bits.used())
    }
    if sym == eob {
      break
    }
    if sym <= 1 {
      let mut run = -1
      let mut weight = 1
      while true {
        if weight >= 2097152 {
          raise @moonzip.Code(at=bits.used())
        }
        if sym == 0 {
          run += weight
        } else {
          run += weight * 2
        }
        weight = weight * 2
        sym = fetcher.next(bits)
        if sym < 0 {
          raise @moonzip.Code(at=bits.used())
        }
        if sym > 1 {
          break
        }
      }
      run += 1
      if block.length() + run > max_block {
        raise @moonzip.Code(at=bits.used())
      }
      let byte = seq_to_unseq[mtf[0]]
      for _ in 0..<run {
        block.push(byte)
      }
      continue
    }
    let v = sym - 1
    if v < 0 || v >= mtf.length() {
      raise @moonzip.Code(at=bits.used())
    }
    let value = mtf[v]
    let mut k = v
    while k > 0 {
      mtf[k] = mtf[k - 1]
      k -= 1
    }
    mtf[0] = value
    if block.length() >= max_block {
      raise @moonzip.Code(at=bits.used())
    }
    block.push(seq_to_unseq[value])
    sym = fetcher.next(bits)
  }
  let n = block.length()
  if n == 0 {
    raise @moonzip.Header(at=bits.used(), what="an empty block")
  }
  if orig_ptr < 0 || orig_ptr >= n {
    raise @moonzip.Header(
      at=bits.used(),
      what="the block's start pointer is past its end",
    )
  }
  // Inverse Burrows-Wheeler: count the bytes, turn that into the first column's
  // offsets, and let the offsets be the permutation.
  let counts = Array::make(256, 0)
  for value in block {
    counts[value] += 1
  }
  let start = Array::make(257, 0)
  for i in 0..<256 {
    start[i + 1] = start[i] + counts[i]
  }
  let next = Array::make(n, 0)
  let cursor = Array::make(257, 0)
  for i in 0..<=256 {
    cursor[i] = start[i]
  }
  for i in 0..<n {
    let value = block[i]
    next[cursor[value]] = i
    cursor[value] += 1
  }
  // Then walk it, undoing the randomisation mask as the reference does: update
  // the countdown, then xor with the mask it now says.
  let plain : Array[Byte] = []
  let mut row = orig_ptr
  let mut rn_to_go = 0
  let mut rt_pos = 0
  for _ in 0..<n {
    row = next[row]
    let mut byte = block[row]
    if randomised {
      if rn_to_go == 0 {
        rn_to_go = rand_nums[rt_pos]
        rt_pos += 1
        if rt_pos == 512 {
          rt_pos = 0
        }
      }
      rn_to_go -= 1
      if rn_to_go == 1 {
        byte = byte ^ 1
      }
    }
    plain.push(byte.to_byte())
  }
  // And the run-length stage: four or more equal bytes were written as four and a
  // count, so four of a kind followed by a byte is not five bytes.
  let out : Array[Byte] = []
  let crc = BlockCrc::new()
  let mut i = 0
  while i < n {
    let byte = plain[i]
    let value = byte.to_int()
    let mut run = 1
    i += 1
    while run < 4 && i < n && plain[i] == byte {
      run += 1
      i += 1
    }
    let mut total = run
    if run == 4 && i < n {
      total = 4 + plain[i].to_int()
      i += 1
    }
    for _ in 0..<total {
      crc.push_byte(value)
      out.push(byte)
    }
  }
  let got = crc.finish()
  if got != want_crc {
    raise @moonzip.Checksum(want=want_crc, got~)
  }
  (Bytes::from_array(out), got)
}
