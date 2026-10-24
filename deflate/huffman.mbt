// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A canonical Huffman code, held as the count of codes at each width and the
/// symbols in code order — which is all a bit-at-a-time decoder needs, and a
/// great deal less than a table (RFC 1951 §3.2.2).
priv struct Huffman {
  counts : FixedArray[Int32]
  symbols : FixedArray[Int32]
}

///|
/// Build a code from the width assigned to each symbol. A width of zero means
/// the symbol is not in the code.
fn Huffman::of(lengths : FixedArray[Int32], n : Int32) -> Huffman {
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
///
/// `None` means the input ran out part-way through. The caller only calls this
/// with enough bytes buffered to finish the symbol, so in practice `None` means
/// the stream ended early — which the caller turns into the error it is.
fn Huffman::read(self : Huffman, br : BitReader) -> Int32? {
  let mut code = 0
  let mut first = 0
  let mut index = 0
  for width in 1..<16 {
    match br.bits(1) {
      None => return None
      Some(bit) => code = code | bit
    }
    let count = self.counts[width]
    if code - first < count {
      return Some(self.symbols[index + (code - first)])
    }
    index += count
    first = (first + count) << 1
    code = code << 1
  }
  None
}

///|
/// The fixed literal/length code of §3.2.6, as a code and a width.
fn fixed_code(sym : Int32) -> (Int32, Int32) {
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
/// The order the code-length code's own lengths are written in (§3.2.7), which
/// puts the lengths most likely to be zero last so they can be left out.
let length_order : FixedArray[Int32] = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
]

// ------------------------------------------------------- the widths of a code

///|
/// The width each symbol of an alphabet gets, no longer than `limit`.
///
/// The tree is built by the two-queue merge — the leaves in weight order
/// against the internal nodes, which come out of the merge in weight order by
/// construction — and the depths it produces are then limited. A tree deeper
/// than `limit` is repaired the way zlib repairs one: every over-deep code is
/// forced up to the limit, and each pair of them pays for a shallower code
/// being split to make room. The result is always a prefix code; on the rare
/// alphabet skewed enough to need the repair it is a fraction of a bit off
/// optimal, which is what the trade buys.
fn code_lengths(freq : Array[Int32], limit : Int32) -> FixedArray[Int32] {
  let n = freq.length()
  let lengths = FixedArray::make(n, 0)
  let used : Array[Int32] = []
  for sym in 0..<n {
    if freq[sym] > 0 {
      used.push(sym)
    }
  }
  // An alphabet with nothing in it needs no code at all, and one with a single
  // symbol needs one bit rather than zero — the format says so explicitly, so
  // that the unused code keeps the table well formed.
  if used.length() == 0 {
    return lengths
  }
  if used.length() == 1 {
    lengths[used[0]] = 1
    return lengths
  }
  // Leaves in weight order, ties by symbol so the result never depends on the
  // order the caller counted in.
  for i in 1..<used.length() {
    let sym = used[i]
    let weight = freq[sym]
    let mut j = i - 1
    while j >= 0 &&
          (freq[used[j]] > weight || (freq[used[j]] == weight && used[j] > sym)) {
      used[j + 1] = used[j]
      j -= 1
    }
    used[j + 1] = sym
  }
  let count = used.length()
  let total = 2 * count - 1
  let weight = FixedArray::make(total, 0)
  let parent = FixedArray::make(total, -1)
  for i in 0..<count {
    weight[i] = freq[used[i]]
  }
  let mut next = count
  let mut leaf = 0
  let mut inner = count
  // The two queues hold `count` nodes between them at the start; each merge
  // takes two and puts one back, so there are `count - 1` of them and the
  // tree ends with one root.
  let mut loose = count
  while loose > 1 {
    let a = if leaf < count && (inner >= next || weight[leaf] <= weight[inner]) {
      let taken = leaf
      leaf += 1
      taken
    } else {
      let taken = inner
      inner += 1
      taken
    }
    let b = if leaf < count && (inner >= next || weight[leaf] <= weight[inner]) {
      let taken = leaf
      leaf += 1
      taken
    } else {
      let taken = inner
      inner += 1
      taken
    }
    weight[next] = weight[a] + weight[b]
    parent[a] = next
    parent[b] = next
    next += 1
    loose -= 1
  }
  let depth = FixedArray::make(total, 0)
  for node = total - 1; node >= count; node = node - 1 {
    depth[node] = if parent[node] >= 0 { depth[parent[node]] + 1 } else { 0 }
  }
  let leaf_depth = FixedArray::make(count, 0)
  for i in 0..<count {
    leaf_depth[i] = depth[parent[i]] + 1
  }
  let mut longest = 0
  for i in 0..<count {
    if leaf_depth[i] > longest {
      longest = leaf_depth[i]
    }
  }
  if longest <= limit {
    for i in 0..<count {
      lengths[used[i]] = leaf_depth[i]
    }
    return lengths
  }
  // Force the over-deep codes up and pay for the room, as above.
  let bl = FixedArray::make(limit + 1, 0)
  let mut overflow = 0
  for i in 0..<count {
    if leaf_depth[i] > limit {
      overflow += 1
      bl[limit] += 1
    } else {
      bl[leaf_depth[i]] += 1
    }
  }
  while overflow > 0 {
    let mut bits = limit - 1
    while bl[bits] == 0 {
      bits -= 1
    }
    bl[bits] -= 1
    bl[bits + 1] += 2
    bl[limit] -= 1
    overflow -= 2
  }
  // Shorter widths go to the symbols that were shallower in the tree.
  for i in 1..<count {
    let sym = used[i]
    let d = leaf_depth[i]
    let mut j = i - 1
    while j >= 0 && (leaf_depth[j] > d || (leaf_depth[j] == d && used[j] > sym)) {
      used[j + 1] = used[j]
      leaf_depth[j + 1] = leaf_depth[j]
      j -= 1
    }
    used[j + 1] = sym
    leaf_depth[j + 1] = d
  }
  let mut at = 0
  for width in 1..<=limit {
    for _ in 0..<bl[width] {
      lengths[used[at]] = width
      at += 1
    }
  }
  lengths
}

///|
/// The canonical code for each symbol, given its width: codes of a width are
/// consecutive integers handed out in symbol order, shortest widths first
/// (§3.2.2). A width of zero leaves the code at zero, and nothing reads it.
fn canonical(
  lengths : FixedArray[Int32],
  n : Int32,
  limit : Int32,
) -> FixedArray[Int32] {
  let counts = FixedArray::make(limit + 2, 0)
  for sym in 0..<n {
    if lengths[sym] > 0 {
      counts[lengths[sym]] += 1
    }
  }
  let codes = FixedArray::make(n, 0)
  let next = FixedArray::make(limit + 2, 0)
  // The first code of a width is one past the last code of the width below,
  // moved up one bit: 0 for the shortest, then (first + count) << 1.
  let mut code = 0
  for width in 1..<=limit {
    code = (code + counts[width - 1]) << 1
    next[width] = code
  }
  for sym in 0..<n {
    let width = lengths[sym]
    if width > 0 {
      codes[sym] = next[width]
      next[width] += 1
    }
  }
  codes
}

///|
/// How far a length table reaches: one past the last symbol with a width, and
/// no less than `least`. Trailing zeros are the format's own way of shortening
/// a table, and a decoder reads exactly as many as this says.
fn reach(lengths : FixedArray[Int32], n : Int32, least : Int32) -> Int32 {
  let mut last = least - 1
  for i in least..<n {
    if lengths[i] != 0 {
      last = i
    }
  }
  last + 1
}
