// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The highest set bit of `value`, or 0 for zero.
fn highbit(value : Int32) -> Int32 {
  let mut n = 0
  let mut left = value
  while left > 1 {
    left = left >> 1
    n += 1
  }
  n
}

///|
/// A normalised distribution: how many of the table's states each symbol owns.
///
/// The value `-1` is the format's way of saying "less than one" — a symbol that
/// occurs but not often enough to earn a whole state, given one from the top of
/// the table so that it can only be reached by a full reset.
priv struct Dist {
  counts : Array[Int32]
  log : Int32
}

///|
/// Read a distribution, and say how many bytes it took.
///
/// This is the fiddliest read in the format: the number of bits per probability
/// shrinks as the remaining probability shrinks, and a probability of zero drags
/// a run of two-bit repeat flags behind it. Transcribed from `FSE_readNCount`,
/// which is the only place the rule is stated exactly.
fn Dist::read(data : BytesView) -> (Dist, Int32) raise @moonzip.Refused {
  let bits = Fb::new(data)
  let log = bits.take(4) + 5
  if log > 9 {
    // Nine is the most zstd uses: literals lengths and match lengths allow nine,
    // offsets only eight.
    raise @moonzip.Header(
      at=0,
      what="a probability table scaled past what the format allows",
    )
  }
  let counts : Array[Int32] = []
  let mut remaining = (1 << log) + 1
  let mut threshold = 1 << log
  let mut nb_bits = log + 1
  let mut previous_zero = false
  while true {
    if previous_zero {
      // Pairs of bits: 0..2 are that many more zeros, 3 means another pair.
      let mut run = 0
      while true {
        let step = bits.take(2)
        run += step
        if step != 3 {
          break
        }
        if run > 255 {
          raise @moonzip.Header(
            at=bits.at(),
            what="a run of absent symbols that never ends",
          )
        }
      }
      for _ in 0..<run {
        counts.push(0)
      }
      if counts.length() > 256 {
        raise @moonzip.Header(
          at=bits.at(),
          what="a distribution with more symbols than an alphabet",
        )
      }
    }
    let ceiling = 2 * threshold - 1 - remaining
    let low = bits.peek(nb_bits) & (threshold - 1)
    let mut value = 0
    if low < ceiling {
      value = low
      bits.skip(nb_bits - 1)
    } else {
      value = bits.peek(nb_bits) & (2 * threshold - 1)
      if value >= threshold {
        value -= ceiling
      }
      bits.skip(nb_bits)
    }
    let count = value - 1
    if count >= 0 {
      remaining -= count
    } else {
      // A "less than one" symbol still costs one point of probability.
      remaining -= 1
    }
    counts.push(count)
    previous_zero = count == 0
    if remaining < threshold {
      if remaining <= 1 {
        break
      }
      nb_bits = highbit(remaining) + 1
      threshold = 1 << (nb_bits - 1)
    }
    if counts.length() >= 256 {
      break
    }
  }
  if remaining != 1 {
    raise @moonzip.Header(
      at=bits.at(),
      what="a probability table that does not add up",
    )
  }
  ({ counts, log, }, bits.at())
}

///|
/// A decoding table: one row per state, each naming a symbol and how to reach the
/// next state.
priv struct Table {
  symbols : Array[Int32]
  nb_bits : Array[Int32]
  baseline : Array[Int32]
  log : Int32
}

///|
/// Build the table, by the reference's rule rather than the specification's
/// prose: symbols in natural order are dealt into states by a modular walk, then
/// each state's next-state arithmetic falls out of how many times its symbol has
/// been seen so far.
fn Table::build(dist : Dist) -> Table raise @moonzip.Refused {
  let counts = dist.counts
  let log = dist.log
  let size = 1 << log
  let symbols = Array::make(size, 0)
  // Cumulative counts, with -1 costing one point like any other present symbol.
  let cumul = Array::make(counts.length() + 1, 0)
  for i in 0..<counts.length() {
    let c = if counts[i] == -1 { 1 } else { counts[i] }
    cumul[i + 1] = cumul[i] + c
  }
  if cumul[counts.length()] > size {
    raise @moonzip.Header(
      at=0,
      what="a probability table that overflows its own scale",
    )
  }
  // "Less than one" symbols are placed from the top down, so reaching them needs
  // a full state read and no arithmetic.
  let mut high = size - 1
  for s in 0..<counts.length() {
    if counts[s] == -1 {
      symbols[high] = s
      high -= 1
    }
  }
  let step = (size >> 1) + (size >> 3) + 3
  let mask = size - 1
  let mut position = 0
  for s in 0..<counts.length() {
    let c = counts[s]
    if c <= 0 {
      continue
    }
    for _ in 0..<c {
      symbols[position] = s
      position = (position + step) & mask
      while position > high {
        position = (position + step) & mask
      }
    }
  }
  if position != 0 {
    raise @moonzip.Header(
      at=0,
      what="a probability table that does not fill its own scale",
    )
  }
  let nb_bits = Array::make(size, 0)
  let baseline = Array::make(size, 0)
  // Each symbol's next-state counter starts at its own *count*, not at where its
  // block of states begins. That is what makes the first rows of a frequent
  // symbol wide and its later rows narrow, and getting it wrong produces a table
  // that decodes every symbol to the right value and every next state to the
  // wrong place.
  let seen = Array::make(counts.length() + 1, 1)
  for i in 0..<counts.length() {
    if counts[i] > 0 {
      seen[i] = counts[i]
    }
  }
  for u in 0..<size {
    let symbol = symbols[u]
    let next = seen[symbol]
    seen[symbol] = next + 1
    let width = log - highbit(next)
    nb_bits[u] = width
    baseline[u] = (next << width) - size
  }
  { symbols, nb_bits, baseline, log, }
}

///|
fn Table::initial(self : Table, bits : Rev) -> Int32 raise @moonzip.Refused {
  bits.take(self.log)
}

///|
fn Table::symbol(self : Table, state : Int32) -> Int32 {
  self.symbols[state]
}

///|
fn Table::step(
  self : Table,
  state : Int32,
  bits : Rev,
) -> Int32 raise @moonzip.Refused {
  self.baseline[state] + bits.take(self.nb_bits[state])
}

///|
/// The table a predefined mode uses, from the three default distributions.
///
/// They are written out as counts rather than as a serialised table because that
/// is what they are: the format states them once and both sides build the table.
fn predefined_literals_length() -> Table raise @moonzip.Refused {
  let counts : Array[Int32] = [
    4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3,
    2, 1, 1, 1, 1, 1, -1, -1, -1, -1,
  ]
  Table::build({ counts, log: 6, })
}

///|
fn predefined_match_length() -> Table raise @moonzip.Refused {
  let counts : Array[Int32] = [
    1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
    -1, -1,
  ]
  Table::build({ counts, log: 6, })
}

///|
fn predefined_offset() -> Table raise @moonzip.Refused {
  let counts : Array[Int32] = [
    1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
    -1, -1, -1,
  ]
  Table::build({ counts, log: 5, })
}

///|
/// A table that decodes one symbol always, for `RLE_Mode`.
fn Table::single(symbol : Int32, log : Int32) -> Table {
  let size = 1 << log
  let symbols = Array::make(size, symbol)
  let nb_bits = Array::make(size, 0)
  let baseline = Array::make(size, 0)
  { symbols, nb_bits, baseline, log, }
}
