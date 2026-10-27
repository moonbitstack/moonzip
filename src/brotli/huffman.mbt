// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A canonical prefix code: the counts per width, the first code of each width,
/// and the symbols in (width, symbol) order. Decoding walks widths from one bit
/// up, which is the same walk DEFLATE describes and the reason the two packages
/// can share a shape without sharing a file — brotli's alphabets, its bit order
/// and its code-length coding are all different.
///
/// Any width up to 15 is legal here. Brotli's own limit is 15 for the body
/// tables and 5 for the code-length table, but nothing in this structure needs
/// to know that.
priv struct Code {
  count : FixedArray[Int32]
  first : FixedArray[Int32]
  offset : FixedArray[Int32]
  symbols : FixedArray[Int32]
  /// Longest width present; the walk stops there.
  width : Int32
  /// Set when the code holds exactly one symbol and consumes no bits at all —
  /// the "simple" form's degenerate case. -1 otherwise.
  only : Int32
}

///|
/// A code with one symbol and no bits: the simple prefix-code form encodes this
/// as a single entry, and every read yields it without touching the stream.
fn Code::one(symbol : Int32) -> Code {
  {
    count: FixedArray::make(16, 0),
    first: FixedArray::make(16, 0),
    offset: FixedArray::make(16, 0),
    symbols: FixedArray::make(1, symbol),
    width: 0,
    only: symbol,
  }
}

///|
/// Build from per-symbol widths (0 = absent), `n` symbols.
///
/// A code is accepted when its widths fill exactly 2^15 sixteenths of the code
/// space, or when it holds a single symbol — the two cases brotli allows. An
/// under-filled code is refused rather than tolerated: it would decode into
/// symbols that were never assigned, and a stream that half-works is worse than
/// one that stops.
fn Code::build(
  widths : FixedArray[Int32],
  n : Int32,
) -> Code raise @moonzip.Refused {
  let count = FixedArray::make(16, 0)
  let mut used = 0
  let mut last = 0
  for i in 0..<n {
    let w = widths[i]
    if w < 0 || w > 15 {
      raise @moonzip.Code(at=i)
    }
    if w > 0 {
      count[w] += 1
      used += 1
      if w > last {
        last = w
      }
    }
  }
  if used == 0 {
    raise @moonzip.Code(at=0)
  }
  let mut left = 1
  for w in 1..<=15 {
    left = (left << 1) - count[w]
    if left < 0 {
      raise @moonzip.Code(at=w)
    }
  }
  if left != 0 && used != 1 {
    raise @moonzip.Code(at=last)
  }
  let offset = FixedArray::make(16, 0)
  let mut sum = 0
  for w in 1..<=15 {
    offset[w] = sum
    sum += count[w]
  }
  let symbols = FixedArray::make(used, 0)
  let cursor = offset.copy()
  for sym in 0..<n {
    let w = widths[sym]
    if w > 0 {
      symbols[cursor[w]] = sym
      cursor[w] += 1
    }
  }
  let first = FixedArray::make(16, 0)
  let mut code = 0
  for w in 1..<=15 {
    first[w] = code
    code = (code + count[w]) << 1
  }
  // A code with one symbol keeps its width: the reference gives such a code a
  // real one-bit (or wider) entry, and only the simple *form* means zero bits.
  // Collapsing here would desynchronise any stream that spells a code this way.
  { count, first, offset, symbols, width: last, only: -1, }
}

///|
/// One symbol. The walk stops at the first width whose range contains the code
/// read so far, which is what makes a canonical code self-delimiting.
fn Code::read(self : Code, bits : Bits) -> Int32 raise @moonzip.Refused {
  if self.only >= 0 {
    return self.only
  }
  let mut code = 0
  let mut w = 1
  while w <= self.width {
    code = (code << 1) | bits.bit()
    let n = self.count[w]
    if code - self.first[w] < n {
      return self.symbols[self.offset[w] + code - self.first[w]]
    }
    w += 1
  }
  raise @moonzip.Code(at=bits.at())
}

///|
/// Width per symbol for a code over `freq`, no wider than `limit`.
///
/// Huffman by the two-queue merge — leaves sorted by weight, internal nodes
/// built in weight order behind them, so the whole tree is one linear pass — and
/// then, if the tree came out too deep, zlib's repair: over-deep codes are
/// forced up to the limit and every pair of them buys a shallower code being
/// split. Near enough to optimal, and never a code that does not add up.
fn code_lengths(freq : FixedArray[Int32], limit : Int32) -> FixedArray[Int32] {
  let n = freq.length()
  let widths = FixedArray::make(n, 0)
  let used : Array[Int32] = []
  for sym in 0..<n {
    if freq[sym] > 0 {
      used.push(sym)
    }
  }
  if used.length() == 0 {
    return widths
  }
  if used.length() == 1 {
    widths[used[0]] = 1
    return widths
  }
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
  let mut longest = 0
  for i in 0..<count {
    leaf_depth[i] = depth[parent[i]] + 1
    if leaf_depth[i] > longest {
      longest = leaf_depth[i]
    }
  }
  if longest <= limit {
    for i in 0..<count {
      widths[used[i]] = leaf_depth[i]
    }
    return widths
  }
  // Clamp every depth to the limit, then look at how much code space that used.
  // Clamping *raises* the Kraft sum — a code at depth 20 forced to 15 takes more
  // room than it did — so the sum is now above 2^limit and has to come back down.
  let hist = FixedArray::make(limit + 1, 0)
  for i in 0..<count {
    let depth = if leaf_depth[i] > limit { limit } else { leaf_depth[i] }
    hist[depth] += 1
    leaf_depth[i] = depth
  }
  let target = 1 << limit
  let mut total = 0
  for w in 1..<=limit {
    total += hist[w] << (limit - w)
  }
  // Push leaves one level deeper, widest bucket first, which is the smallest
  // correction available: a leaf moved from `w` to `w + 1` gives back 2^(limit-w-1).
  while total > target {
    let mut moved = false
    let mut w = limit - 1
    while w >= 1 {
      if hist[w] > 0 && total - (1 << (limit - w - 1)) >= target {
        hist[w] -= 1
        hist[w + 1] += 1
        total -= 1 << (limit - w - 1)
        moved = true
        break
      }
      w -= 1
    }
    if !moved {
      break
    }
  }
  if total != target {
    // The greedy correction cannot always land exactly, and an inexact code is
    // not a code: the reader would decode symbols that were never assigned. Fall
    // back to the shallowest complete distribution there is — two widths at most,
    // one level apart — and let the frequencies decide who gets the short one.
    return flat_lengths(used, freq, limit)
  }
  // Shortest widths to the symbols that were shallowest in the Huffman tree.
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
  for w in 1..<=limit {
    for _ in 0..<hist[w] {
      widths[used[at]] = w
      at += 1
    }
  }
  widths
}

///|
/// The flattest complete code over `used`: two adjacent widths, the shorter one
/// handed to the most frequent symbols.
///
/// A complete code with `k` leaves needs `2^w - k` of them at width `w - 1` and
/// the rest at width `w`, where `2^(w-1) < k <= 2^w`. That identity holds for
/// every `k`, which is what makes this a fallback that cannot fail.
fn flat_lengths(
  used : Array[Int32],
  freq : FixedArray[Int32],
  limit : Int32,
) -> FixedArray[Int32] {
  let widths = FixedArray::make(freq.length(), 0)
  let k = used.length()
  if k == 0 {
    return widths
  }
  if k == 1 {
    widths[used[0]] = 1
    return widths
  }
  let mut w = 1
  while 1 << w < k {
    w += 1
  }
  if w > limit {
    w = limit
  }
  let short = (1 << w) - k
  // Most frequent first, so the shorter width lands on the symbols that use it.
  let order = used.copy()
  for i in 1..<k {
    let sym = order[i]
    let mut j = i - 1
    while j >= 0 &&
          (
            freq[order[j]] < freq[sym] ||
            (freq[order[j]] == freq[sym] && order[j] > sym)
          ) {
      order[j + 1] = order[j]
      j -= 1
    }
    order[j + 1] = sym
  }
  for i in 0..<k {
    widths[order[i]] = if i < short { w - 1 } else { w }
  }
  widths
}

///|
/// The canonical code for each symbol at its width, index-aligned with
/// `widths`. Only the encoder needs these, to write a symbol out.
fn canonical_codes(widths : FixedArray[Int32], n : Int32) -> FixedArray[Int32] {
  let count = FixedArray::make(16, 0)
  for i in 0..<n {
    if widths[i] > 0 {
      count[widths[i]] += 1
    }
  }
  let first = FixedArray::make(16, 0)
  let mut code = 0
  for w in 1..<=15 {
    first[w] = code
    code = (code + count[w]) << 1
  }
  let cursor = first.copy()
  let codes = FixedArray::make(n, 0)
  for sym in 0..<n {
    let w = widths[sym]
    if w > 0 {
      codes[sym] = cursor[w]
      cursor[w] += 1
    }
  }
  codes
}

///|
/// Write one symbol of a code built by `canonical_codes`.
///
/// Brotli reads the first bit of a code first, and the first bit of a canonical
/// code is its most significant one, so the bits go out high to low.
fn write_code(
  w : Writer,
  widths : FixedArray[Int32],
  codes : FixedArray[Int32],
  symbol : Int32,
) -> Unit {
  let width = widths[symbol]
  let code = codes[symbol]
  for i in 0..<width {
    w.put((code >> (width - 1 - i)) & 1, 1)
  }
}
