// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The block, after the run-length stage that feeds the sort.
///
/// A run of four or more equal bytes becomes four bytes and a count, so a file of
/// nothing but newlines is a few hundred bytes before the Burrows-Wheeler even
/// sees it — which is the point: the sort is what costs, and this makes it cost
/// less.
///
/// Returns the encoded block, how far into the input it got, and the CRC of the
/// input it consumed. The CRC is over the *original* bytes, because that is what
/// the trailer has to be checked against by a reader who has already undone this.
fn take_block(
  data : Array[Byte],
  from : Int32,
  max : Int32,
) -> (Array[Byte], Int32, UInt32) {
  let out : Array[Byte] = []
  let crc = BlockCrc::new()
  let mut i = from
  while i < data.length() && out.length() < max {
    let byte = data[i].to_int()
    let mut run = 1
    i += 1
    // Two hundred and fifty-five is the most a run can be, because the count
    // byte has to hold `length - 4` and a byte holds 255.
    while i < data.length() && data[i].to_int() == byte && run < 255 {
      run += 1
      i += 1
    }
    for _ in 0..<run {
      crc.push_byte(byte)
    }
    if run < 4 {
      for _ in 0..<run {
        out.push(byte.to_byte())
      }
    } else {
      for _ in 0..<4 {
        out.push(byte.to_byte())
      }
      out.push((run - 4).to_byte())
    }
  }
  (out, i, crc.finish())
}

///|
/// The Burrows-Wheeler transform: the sorted rotations' last column, and where the
/// unsorted block landed among them.
///
/// Sorting the rotations outright is quadratic, so this doubles instead: rank each
/// rotation by its first byte, then by its first two, its first four, and so on,
/// each round sorting by a pair of ranks that the previous round already
/// computed. `n` rounds of a linear pass, which is the standard trade and the
/// reason the format has a block size limit rather than none.
fn bwt(block : Array[Byte]) -> (Array[Int32], Int32) {
  let n = block.length()
  let sa = Array::make(n, 0)
  let rank = Array::make(n, 0)
  let work = Array::make(n, 0)
  let fresh = Array::make(n, 0)
  let count = Array::make(257, 0)
  for i in 0..<n {
    count[block[i].to_int() + 1] += 1
  }
  for i in 1..<=256 {
    count[i] += count[i - 1]
  }
  for i in 0..<n {
    let byte = block[i].to_int()
    sa[count[byte]] = i
    count[byte] += 1
  }
  let mut classes = 1
  rank[sa[0]] = 0
  for i in 1..<n {
    if block[sa[i]] != block[sa[i - 1]] {
      classes += 1
    }
    rank[sa[i]] = classes - 1
  }
  let mut step = 1
  while step < n && classes < n {
    // The rotation that starts `step` earlier, which is its second half.
    for i in 0..<n {
      let back = sa[i] - step
      work[i] = if back < 0 { back + n } else { back }
    }
    let buckets = Array::make(classes + 1, 0)
    for i in 0..<n {
      buckets[rank[i] + 1] += 1
    }
    for i in 1..<=classes {
      buckets[i] += buckets[i - 1]
    }
    for i in 0..<n {
      let r = rank[work[i]]
      sa[buckets[r]] = work[i]
      buckets[r] += 1
    }
    fresh[sa[0]] = 0
    let mut next_class = 1
    for i in 1..<n {
      let a = sa[i]
      let b = sa[i - 1]
      let a2 = if a + step < n { a + step } else { a + step - n }
      let b2 = if b + step < n { b + step } else { b + step - n }
      if rank[a] != rank[b] || rank[a2] != rank[b2] {
        next_class += 1
      }
      fresh[a] = next_class - 1
    }
    for i in 0..<n {
      rank[i] = fresh[i]
    }
    classes = next_class
    step = step * 2
  }
  let last = Array::make(n, 0)
  let mut orig = 0
  for i in 0..<n {
    let start = sa[i]
    last[i] = if start == 0 {
      block[n - 1].to_int()
    } else {
      block[start - 1].to_int()
    }
    if start == 0 {
      orig = i
    }
  }
  (last, orig)
}

///|
/// Move-to-front, then the run-length stage on the zeros it produces.
///
/// Sorting made the contexts adjacent, so most bytes are the one that was last
/// seen at the same context — index zero — and a long run of zeros encodes as a
/// handful of two-valued symbols. This is the stage that turns "sorted" into
/// "compressible", and the two-symbol alphabet is why the count is written in
/// binary rather than as a number.
///
/// Returns the symbol stream and how often each symbol occurs; the frequencies are
/// what the Huffman tables are built from.
fn mtf_symbols(
  last : Array[Int32],
  in_use : Array[Bool],
) -> (Array[Int32], Array[Int32], Int32) {
  let seq_of = Array::make(256, -1)
  let mut n = 0
  for byte in 0..<256 {
    if in_use[byte] {
      seq_of[byte] = n
      n += 1
    }
  }
  let mtf = Array::make(n, 0)
  for i in 0..<n {
    mtf[i] = i
  }
  let symbols : Array[Int32] = []
  let freq = Array::make(n + 2, 0)
  let mut pending = 0
  for value in last {
    let index = seq_of[value]
    if mtf[0] == index {
      pending += 1
      continue
    }
    while pending > 0 {
      // The count is a hundred and twenty-eight at most per two symbols, and the
      // loop reads one two-symbol digit at a time from the bottom.
      let mut left = pending - 1
      while true {
        let digit = if (left & 1) == 1 { 1 } else { 0 }
        symbols.push(digit)
        freq[digit] += 1
        if left < 2 {
          break
        }
        left = (left - 2) / 2
      }
      pending = 0
    }
    let mut at = 1
    while mtf[at] != index {
      at += 1
    }
    let moved = mtf[at]
    let mut k = at
    while k > 0 {
      mtf[k] = mtf[k - 1]
      k -= 1
    }
    mtf[0] = moved
    symbols.push(at + 1)
    freq[at + 1] += 1
  }
  while pending > 0 {
    let mut left = pending - 1
    while true {
      let digit = if (left & 1) == 1 { 1 } else { 0 }
      symbols.push(digit)
      freq[digit] += 1
      if left < 2 {
        break
      }
      left = (left - 2) / 2
    }
    pending = 0
  }
  symbols.push(n + 1)
  freq[n + 1] += 1
  (symbols, freq, n)
}

///|
/// The two queues a Huffman merge needs: sorted leaves, and the internal nodes
/// created so far, which come out in order because their weights only grow.
priv struct Merger {
  weights : Array[Int32]
  leaves : Int32
  mut leaf : Int32
  mut loose : Int32
  mut next : Int32
}

///|
fn Merger::pick(self : Merger) -> Int32 {
  if self.leaf < self.leaves &&
    (
      self.loose >= self.next ||
      self.weights[self.leaf] <= self.weights[self.loose]
    ) {
    self.leaf += 1
    self.leaf - 1
  } else {
    self.loose += 1
    self.loose - 1
  }
}

///|
/// Code lengths for a symbol set, at most twenty bits each.
///
/// Every symbol gets a length, including the ones that never occur, because the
/// format sends one length per symbol and a zero is not a length. The two-queue
/// merge gives the optimal tree; the repair afterwards is zlib's, and it handles
/// the case where a skewed distribution wants a code longer than the format
/// allows.
fn lengths_from(weights : Array[Int32], limit : Int32) -> Array[Int32] {
  let n = weights.length()
  let lengths = Array::make(n, 1)
  if n <= 1 {
    return lengths
  }
  let order : Array[Int32] = []
  for i in 0..<n {
    order.push(i)
  }
  for i in 1..<n {
    let value = order[i]
    let mut j = i
    while j > 0 {
      let before = order[j - 1]
      let swap = weights[before] > weights[value] ||
        (weights[before] == weights[value] && before > value)
      if !swap {
        break
      }
      order[j] = before
      j -= 1
    }
    order[j] = value
  }
  let total = 2 * n - 1
  let node_weight = Array::make(total, 0)
  let parent = Array::make(total, -1)
  for k in 0..<n {
    let w = weights[order[k]]
    node_weight[k] = if w > 0 { w } else { 1 }
  }
  let merger = Merger::{
    weights: node_weight,
    leaves: n,
    leaf: 0,
    loose: n,
    next: n,
  }
  while merger.next < total {
    let a = merger.pick()
    let b = merger.pick()
    node_weight[merger.next] = node_weight[a] + node_weight[b]
    parent[a] = merger.next
    parent[b] = merger.next
    merger.next += 1
  }
  let depth = Array::make(n, 0)
  let mut deepest = 0
  for k in 0..<n {
    let mut node = k
    let mut d = 0
    while parent[node] >= 0 {
      node = parent[node]
      d += 1
    }
    depth[order[k]] = d
    if d > deepest {
      deepest = d
    }
  }
  // Sized by whichever is larger: the histogram has to hold a depth the tree
  // actually reached *and* the limit the code is squeezed into, and those are two
  // different numbers when the repair is needed.
  let count = Array::make(
    (if deepest > limit { deepest } else { limit }) + 2,
    0,
  )
  for i in 0..<n {
    count[depth[i]] += 1
  }
  if deepest > limit {
    // Squeeze everything past the limit into it, then give the code back its
    // one-ness: every clamp makes the length distribution too short by two, and
    // moving one symbol down a level and two up is what repays it.
    let mut overflow = 0
    let mut d = limit + 1
    while d <= deepest {
      overflow += count[d]
      count[limit] += count[d]
      count[d] = 0
      d += 1
    }
    while overflow > 0 {
      let mut d = limit - 1
      while count[d] == 0 {
        d -= 1
      }
      count[d] -= 1
      count[d + 1] += 2
      count[limit] -= 1
      overflow -= 2
    }
  }
  // The symbols that were deepest are the ones that were rarest, so they are the
  // ones that can afford the long codes.
  let by_depth : Array[Int32] = []
  for d in 1..<=deepest {
    for symbol in 0..<n {
      if depth[symbol] == d {
        by_depth.push(symbol)
      }
    }
  }
  let mut k = 0
  for d in 1..<=limit {
    for _ in 0..<count[d] {
      if k < n {
        lengths[by_depth[k]] = d
        k += 1
      }
    }
  }
  lengths
}
