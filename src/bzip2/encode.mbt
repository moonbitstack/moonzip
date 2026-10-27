// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The largest block the format allows for a level: a hundred kilobytes per unit,
/// so level nine is nine hundred.
fn block_size(level : Int32) -> Int32 {
  100000 * level
}

///|
/// Compress into bzip2.
///
/// `level` is one to nine and means what it means everywhere else: how much memory
/// the compressor may use on a block, and so how far back a match can reach. Nine
/// is the default because the format's own default is nine, and a caller who cares
/// has an opinion.
///
/// ```moonbit nocheck
/// let packed = @bzip2.bzip2(body[:], level=9)
/// ```
pub fn bzip2(data : BytesView, level~ : Int32 = 9) -> Bytes {
  let size = if level < 1 { 1 } else if level > 9 { 9 } else { level }
  let sink = Sink::new()
  for b in [0x42, 0x5A, 0x68, 0x30 + size] {
    sink.bits(b, 8)
  }
  let raw = data.to_array()
  let mut at = 0
  let mut combined = 0U
  while at < raw.length() {
    let (block, next, crc) = take_block(raw, at, block_size(size))
    write_block(sink, block, crc)
    combined = ((combined << 1) | (combined >> 31)) ^ crc
    at = next
  }
  for b in end_marker {
    sink.bits(b, 8)
  }
  sink.word(combined)
  sink.finish()
}

///|
/// One block: the Burrows-Wheeler transform, the move-to-front symbol stream, and
/// the Huffman tables that encode it.
fn write_block(sink : Sink, block : Array[Byte], crc : UInt32) -> Unit {
  let (last, orig) = bwt(block)
  let in_use = Array::make(256, false)
  for value in last {
    in_use[value] = true
  }
  let (symbols, freq, n_in_use) = mtf_symbols(last, in_use)
  let alpha = n_in_use + 2
  for b in block_marker {
    sink.bits(b, 8)
  }
  sink.word(crc)
  // Never randomised. The flag exists so that a block with a great many runs can
  // be stirred before sorting, but the reference stopped setting it and a decoder
  // that honours it is more than a writer that uses it needs.
  sink.bits(0, 1)
  sink.bits(orig, 24)
  // Which bytes the block uses: sixteen bits of groups, then sixteen bits per
  // group that has any.
  let grouped = Array::make(16, false)
  for group in 0..<16 {
    for k in 0..<16 {
      if in_use[group * 16 + k] {
        grouped[group] = true
      }
    }
  }
  for group in 0..<16 {
    sink.bits(if grouped[group] { 1 } else { 0 }, 1)
  }
  for group in 0..<16 {
    if grouped[group] {
      for k in 0..<16 {
        sink.bits(if in_use[group * 16 + k] { 1 } else { 0 }, 1)
      }
    }
  }
  let n_mtf = symbols.length()
  // The reference's own thresholds, which trade table overhead against how well a
  // table fits: a small block cannot afford six tables' worth of lengths.
  let n_groups = if n_mtf < 200 {
    2
  } else if n_mtf < 600 {
    3
  } else if n_mtf < 1200 {
    4
  } else if n_mtf < 2400 {
    5
  } else {
    6
  }
  let lengths = split_tables(freq, alpha, n_groups, n_mtf)
  // Four rounds of "assign each group of fifty symbols to the table that codes it
  // cheapest, then rebuild the tables from what they were given". The last pass
  // only assigns, so the selectors that are written describe the lengths that are
  // written.
  let selectors = Array::make(n_mtf / 50 + 1, 0)
  let mut n_selectors = 0
  for round in 0..<5 {
    n_selectors = 0
    let usage = Array::make(n_groups * alpha, 0)
    let mut gs = 0
    while gs < n_mtf {
      let mut ge = gs + 49
      if ge >= n_mtf {
        ge = n_mtf - 1
      }
      let mut best = 0
      let mut best_cost = 2147483647
      for table in 0..<n_groups {
        let mut cost = 0
        for i in gs..<=ge {
          cost += lengths[table * alpha + symbols[i]]
        }
        if cost < best_cost {
          best_cost = cost
          best = table
        }
      }
      selectors[n_selectors] = best
      n_selectors += 1
      for i in gs..<=ge {
        usage[best * alpha + symbols[i]] += 1
      }
      gs = ge + 1
    }
    if round < 4 {
      for table in 0..<n_groups {
        let weights : Array[Int32] = []
        for symbol in 0..<alpha {
          weights.push(usage[table * alpha + symbol])
        }
        let fresh = lengths_from(weights, 20)
        for symbol in 0..<alpha {
          lengths[table * alpha + symbol] = fresh[symbol]
        }
      }
    }
  }
  sink.bits(n_groups, 3)
  // Fifteen bits, and the field the decoder reads as a count rather than as a
  // unary run. Getting this wrong produces a stream that decodes its first table
  // perfectly and then reads the data as code lengths.
  sink.bits(n_selectors, 15)
  let order = Array::make(n_groups, 0)
  for i in 0..<n_groups {
    order[i] = i
  }
  for i in 0..<n_selectors {
    let value = selectors[i]
    let mut j = 0
    while order[j] != value {
      j += 1
    }
    for _ in 0..<j {
      sink.bits(1, 1)
    }
    sink.bits(0, 1)
    let moved = order[j]
    let mut k = j
    while k > 0 {
      order[k] = order[k - 1]
      k -= 1
    }
    order[0] = moved
  }
  // The lengths, as deltas: one bit to say "same", two to say which way.
  for table in 0..<n_groups {
    let mut curr = lengths[table * alpha]
    sink.bits(curr, 5)
    for symbol in 0..<alpha {
      let want = lengths[table * alpha + symbol]
      while curr != want {
        sink.bits(1, 1)
        if want > curr {
          sink.bits(0, 1)
          curr += 1
        } else {
          sink.bits(1, 1)
          curr -= 1
        }
      }
      sink.bits(0, 1)
    }
  }
  let codes = assign_codes(lengths, alpha, n_groups)
  for i in 0..<n_mtf {
    let table = selectors[i / 50]
    let symbol = symbols[i]
    sink.bits(codes[table * alpha + symbol], lengths[table * alpha + symbol])
  }
}

///|
/// The first cut at the tables: symbols in frequency order are dealt out to the
/// tables in contiguous ranges, so each table starts out knowing a different part
/// of the alphabet. Without that they would all start identical and stay that way,
/// and the format's whole reason for having six tables would be lost.
fn split_tables(
  freq : Array[Int32],
  alpha : Int32,
  n_groups : Int32,
  n_mtf : Int32,
) -> Array[Int32] {
  let lengths = Array::make(n_groups * alpha, 0)
  let mut left = n_groups
  let mut remaining = n_mtf
  let mut gs = 0
  while left > 0 {
    let target = remaining / left
    let mut ge = gs - 1
    let mut acc = 0
    while acc < target && ge < alpha - 1 {
      ge += 1
      acc += freq[ge]
    }
    if ge > gs && left != n_groups && left != 1 && (n_groups - left) % 2 == 1 {
      acc -= freq[ge]
      ge -= 1
    }
    for v in 0..<alpha {
      lengths[(left - 1) * alpha + v] = if v >= gs && v <= ge { 1 } else { 12 }
    }
    left -= 1
    gs = ge + 1
    remaining -= acc
  }
  lengths
}

///|
/// The canonical code number for every symbol of every table.
///
/// The decoder finds a symbol by `perm[code - base[length]]`, so running that
/// backwards is the whole of it: the `k`-th entry of `perm` is the symbol whose
/// code is `base[length] + k`.
fn assign_codes(
  lengths : Array[Int32],
  alpha : Int32,
  n_groups : Int32,
) -> Array[Int32] {
  let codes = Array::make(n_groups * alpha, 0)
  for table in 0..<n_groups {
    let row : Array[Int32] = []
    for symbol in 0..<alpha {
      row.push(lengths[table * alpha + symbol])
    }
    let built = Codes::build(row, alpha)
    let perm = built.perm
    let base = built.base
    for k in 0..<perm.length() {
      let symbol = perm[k]
      codes[table * alpha + symbol] = base[lengths[table * alpha + symbol]] + k
    }
  }
  codes
}
