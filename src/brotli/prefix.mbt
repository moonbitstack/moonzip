// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Prefix codes, in the two shapes brotli allows a stream to spell them in.
///
/// *Simple*: at most four symbols, written out literally with widths implied by
/// their count. That is what a tree with one or two entries uses, and it costs a
/// handful of bits.
///
/// *Complex*: the widths of the alphabet are themselves entropy coded, with a
/// separate 18-symbol code over them, plus two run-length symbols (16 = "same as
/// the last width", 17 = "zero"). That code's own widths are spelled in a *fixed
/// prefix code*, not in fixed-width fields. Everything above four symbols goes
/// this way, which in practice is every literal table.
///
/// The order below is not the numeric order: brotli writes the eighteen
/// code-length widths starting at symbol 1 and leaving 0 until fifth, so the
/// values that matter most — small widths — arrive early and the reader can stop
/// as soon as the code is full.
let cl_order : FixedArray[Int32] = [
  1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15,
]

///|
/// The fixed code that spells the eighteen code-length widths: width 2 for 0, 3
/// and 4, width 3 for 2, width 4 for 1 and 5 (RFC 7932 §3.5).
///
/// The field is not four raw bits per value, which is the mistake that keeps this
/// format's bit layout on the interesting side: it is a prefix code whose codes
/// happen to be two, three or four bits long.
fn cl_code() -> Code raise @moonzip.Refused {
  Code::build([2, 4, 3, 2, 2, 4], 6)
}

///|
let cl_fixed_widths : FixedArray[Int32] = [2, 4, 3, 2, 2, 4]

///|
let cl_fixed_codes : FixedArray[Int32] = canonical_codes(cl_fixed_widths, 6)

///|
/// How many bits it takes to name a value below `x`, which is what a simple
/// prefix code spends on each symbol. The reference calls this `Log2Floor` and it
/// is not the floor of the logarithm: 255 needs 8 bits, not 7, or half the
/// literal alphabet would be unnameable.
fn bit_width(x : Int32) -> Int32 {
  let mut value = x
  let mut width = 0
  while value > 0 {
    value = value >> 1
    width += 1
  }
  width
}

///|
/// Read one prefix code. `alphabet_max` sizes the fields that spell out a simple
/// code, `alphabet_limit` bounds the symbols it may name; brotli passes two
/// different numbers for distances under the large-window extension and the same
/// number everywhere else.
fn read_prefix(
  bits : Bits,
  alphabet_max : Int32,
  alphabet_limit : Int32,
) -> Code raise @moonzip.Refused {
  let kind = bits.take(2)
  if kind == 1 {
    return read_simple(bits, alphabet_max, alphabet_limit)
  }
  return read_complex(bits, kind, alphabet_limit)
}

///|
fn read_simple(
  bits : Bits,
  alphabet_max : Int32,
  alphabet_limit : Int32,
) -> Code raise @moonzip.Refused {
  let count = bits.take(2) + 1
  let width = bit_width(alphabet_max - 1)
  let symbols = FixedArray::make(count, 0)
  for i in 0..<count {
    let symbol = bits.take(width)
    if symbol >= alphabet_limit {
      raise @moonzip.Header(at=bits.at(), what="a symbol outside its alphabet")
    }
    symbols[i] = symbol
  }
  for i in 0..<count {
    for j in (i + 1)..<count {
      if symbols[i] == symbols[j] {
        raise @moonzip.Header(at=bits.at(), what="a symbol listed twice")
      }
    }
  }
  if count == 1 {
    return Code::one(symbols[0])
  }
  let widths = FixedArray::make(alphabet_limit, 0)
  if count == 2 {
    widths[symbols[0]] = 1
    widths[symbols[1]] = 1
  } else if count == 3 {
    widths[symbols[0]] = 1
    widths[symbols[1]] = 2
    widths[symbols[2]] = 2
  } else {
    // Four symbols come in two shapes; the second bit picks the skewed one,
    // where the first symbol gets one bit and the last two get three.
    let skewed = bits.take(1)
    if skewed == 0 {
      for i in 0..<4 {
        widths[symbols[i]] = 2
      }
    } else {
      widths[symbols[0]] = 1
      widths[symbols[1]] = 2
      widths[symbols[2]] = 3
      widths[symbols[3]] = 3
    }
  }
  Code::build(widths, alphabet_limit)
}

///|
fn read_complex(
  bits : Bits,
  skip : Int32,
  alphabet_limit : Int32,
) -> Code raise @moonzip.Refused {
  let fixed = cl_code()
  let cl_widths = FixedArray::make(18, 0)
  let mut space = 32
  let mut codes = 0
  let mut i = skip
  while i < 18 {
    let value = fixed.read(bits)
    let idx = cl_order[i]
    cl_widths[idx] = value
    if value > 0 {
      space -= 32 >> value
      codes += 1
      if space <= 0 {
        break
      }
    }
    i += 1
  }
  if codes != 1 && space != 0 {
    raise @moonzip.Header(
      at=bits.at(),
      what="a code-length code that does not add up",
    )
  }
  // A code-length code with one symbol costs no bits at all: the reference
  // decoder builds a table entry of width zero for it, and the reference encoder
  // zeroes that symbol's width before writing the run lengths. Treating it as a
  // one-bit code reads the stream one bit early from there on.
  let mut sole = -1
  let mut distinct = 0
  for i in 0..<18 {
    if cl_widths[i] > 0 {
      sole = i
      distinct += 1
    }
  }
  let cl = if distinct == 1 {
    Code::one(sole)
  } else {
    Code::build(cl_widths, 18)
  }
  let widths = FixedArray::make(alphabet_limit, 0)
  let mut symbol = 0
  let mut previous = 8
  let mut repeat = 0
  let mut repeat_width = 0
  space = 32768
  while symbol < alphabet_limit && space > 0 {
    let width = cl.read(bits)
    if width < 16 {
      repeat = 0
      if width > 0 {
        widths[symbol] = width
        previous = width
        space -= 32768 >> width
        if space < 0 {
          raise @moonzip.Header(
            at=bits.at(),
            what="a code longer than the code space",
          )
        }
      }
      symbol += 1
    } else {
      // 16 repeats the last non-zero width three to six times, 17 repeats a
      // zero three to ten times. Both may be chained: a second 16 continues the
      // same run, which is why the running total is kept and the step's share is
      // the difference.
      let extra = if width == 16 { 2 } else { 3 }
      let target = if width == 16 { previous } else { 0 }
      let delta = bits.take(extra)
      if repeat_width != target {
        repeat = 0
        repeat_width = target
      }
      let before = repeat
      if repeat > 0 {
        repeat = (repeat - 2) << extra
      }
      repeat += delta + 3
      let added = repeat - before
      if symbol + added > alphabet_limit {
        raise @moonzip.Header(
          at=bits.at(),
          what="a repeat past the end of its alphabet",
        )
      }
      if target != 0 {
        for k in 0..<added {
          widths[symbol + k] = target
        }
        space -= added << (15 - target)
        if space < 0 {
          raise @moonzip.Header(
            at=bits.at(),
            what="a code longer than the code space",
          )
        }
      }
      symbol += added
    }
  }
  if space != 0 {
    raise @moonzip.Header(
      at=bits.at(),
      what="a code that leaves the code space unfilled",
    )
  }
  Code::build(widths, alphabet_limit)
}

///|
/// Write one prefix code. The caller has already decided the widths; this picks
/// the cheaper of the two spellings and writes it.
fn write_prefix(
  w : Writer,
  widths : FixedArray[Int32],
  alphabet_max : Int32,
) -> Unit {
  let mut n = widths.length()
  while n > 0 && widths[n - 1] == 0 {
    n -= 1
  }
  let mut distinct = 0
  for i in 0..<n {
    if widths[i] > 0 {
      distinct += 1
    }
  }
  if distinct <= 4 {
    write_simple(w, widths, n, alphabet_max)
  } else {
    write_complex(w, widths, n)
  }
}

///|
fn write_simple(
  w : Writer,
  widths : FixedArray[Int32],
  n : Int32,
  alphabet_max : Int32,
) -> Unit {
  let symbols = FixedArray::make(4, 0)
  let mut count = 0
  for i in 0..<n {
    if widths[i] > 0 && count < 4 {
      symbols[count] = i
      count += 1
    }
  }
  let width = bit_width(alphabet_max - 1)
  w.put(1, 2)
  w.put(count - 1, 2)
  for i in 0..<count {
    w.put(symbols[i], width)
  }
  if count == 4 {
    // Both shapes are two bits for four symbols; the flat one is the one that
    // keeps every literal the same width, which is what a four-symbol alphabet
    // almost always wants.
    w.put(0, 1)
  }
}

///|
/// Append `count` copies of width `value` to the code-length stream.
///
/// A repeat symbol does not mean "three more"; it means "the run is now this
/// long", and each further repeat of the same kind extends the run
/// exponentially: `next = ((previous - 2) << extra) + delta + 3`. So a run longer
/// than six is written as a chain of repeats with the *largest* share first — the
/// chain is emitted back to front for exactly this reason, which is why the loop
/// below collects deltas and then walks them backwards.
fn push_repeats(
  previous : Int32,
  value : Int32,
  count : Int32,
  symbols : Array[Int32],
  extras : Array[Int32],
) -> Unit {
  let mut left = count
  if previous != value {
    symbols.push(value)
    extras.push(0)
    left -= 1
  }
  if left == 7 {
    symbols.push(value)
    extras.push(0)
    left -= 1
  }
  if left < 3 {
    for _ in 0..<left {
      symbols.push(value)
      extras.push(0)
    }
    return
  }
  let deltas : Array[Int32] = []
  left -= 3
  while true {
    deltas.push(left & 3)
    left = left >> 2
    if left == 0 {
      break
    }
    left -= 1
  }
  for i = deltas.length() - 1; i >= 0; i = i - 1 {
    symbols.push(16)
    extras.push(deltas[i])
  }
}

///|
/// The same for a run of zeros, in base eight.
fn push_zeros(
  count : Int32,
  symbols : Array[Int32],
  extras : Array[Int32],
) -> Unit {
  let mut left = count
  if left == 11 {
    symbols.push(0)
    extras.push(0)
    left -= 1
  }
  if left < 3 {
    for _ in 0..<left {
      symbols.push(0)
      extras.push(0)
    }
    return
  }
  let deltas : Array[Int32] = []
  left -= 3
  while true {
    deltas.push(left & 7)
    left = left >> 3
    if left == 0 {
      break
    }
    left -= 1
  }
  for i = deltas.length() - 1; i >= 0; i = i - 1 {
    symbols.push(17)
    extras.push(deltas[i])
  }
}

///|
fn write_complex(w : Writer, widths : FixedArray[Int32], n : Int32) -> Unit {
  let symbols : Array[Int32] = []
  let extras : Array[Int32] = []
  let mut previous = 8
  let mut i = 0
  while i < n {
    let value = widths[i]
    let mut run = 1
    while i + run < n && widths[i + run] == value {
      run += 1
    }
    if value == 0 {
      push_zeros(run, symbols, extras)
    } else {
      push_repeats(previous, value, run, symbols, extras)
      previous = value
    }
    i += run
  }
  let freq = FixedArray::make(18, 0)
  for k in 0..<symbols.length() {
    freq[symbols[k]] += 1
  }
  let cl_widths = code_lengths(freq, 5)
  // The first positions of the order are the widths a well-filled code rarely
  // needs, so a code that does not use them can say so once instead of eight
  // times.
  let mut skip = 0
  for candidate in [3, 2] {
    let mut zeros = 0
    while zeros < candidate && cl_widths[cl_order[zeros]] == 0 {
      zeros += 1
    }
    if zeros == candidate {
      skip = candidate
      break
    }
  }
  w.put(skip, 2)
  let mut space = 32
  let mut k = skip
  while k < 18 {
    let value = cl_widths[cl_order[k]]
    write_code(w, cl_fixed_widths, cl_fixed_codes, value)
    if value > 0 {
      space -= 32 >> value
      if space == 0 {
        break
      }
    }
    k += 1
  }
  let cl_codes = canonical_codes(cl_widths, 18)
  let mut cl_sole = -1
  let mut cl_distinct = 0
  for i in 0..<18 {
    if cl_widths[i] > 0 {
      cl_sole = i
      cl_distinct += 1
    }
  }
  let _ = cl_sole
  for j in 0..<symbols.length() {
    let symbol = symbols[j]
    if cl_distinct != 1 {
      write_code(w, cl_widths, cl_codes, symbol)
    }
    if symbol == 16 {
      w.put(extras[j], 2)
    } else if symbol == 17 {
      w.put(extras[j], 3)
    }
  }
}
