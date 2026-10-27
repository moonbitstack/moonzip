// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A Huffman tree described the way zstd describes one: a weight per symbol, with
/// the last present symbol's weight left out because it can be computed from the
/// others.
///
/// The weight runs the other way from the code length — a heavier symbol has a
/// *shorter* code — which is why the conversion is `maxBits + 1 - weight` and not
/// something more obvious.
priv struct Tree {
  /// Symbols ordered by length ascending, then symbol ascending.
  ordered : Array[Int32]
  /// Where each length's run starts in `ordered`.
  start : Array[Int32]
  /// How many symbols have each length.
  count : Array[Int32]
  /// The first code of each length.
  first_code : Array[Int32]
  max_bits : Int32
}

///|
/// Read the weight series from the start of `data`, and say how much it took.
fn Tree::read(data : BytesView) -> (Tree, Int32) raise @moonzip.Refused {
  if data.length() == 0 {
    raise @moonzip.Truncated(at=0)
  }
  let header = data[0].to_int()
  let weights : Array[Int32] = []
  let mut used = 0
  if header >= 128 {
    // Everything is spelled out, four bits each, high nibble first.
    let count = header - 127
    let bytes = (count + 1) / 2
    if data.length() < 1 + bytes {
      raise @moonzip.Truncated(at=data.length())
    }
    for i in 0..<count {
      let byte = data[1 + i / 2].to_int()
      weights.push(if i % 2 == 0 { byte >> 4 } else { byte & 0x0F })
    }
    used = 1 + bytes
  } else {
    // Compressed with FSE, two interleaved states, ending when the bits run out
    // rather than at a stated count — which is why the loop below is watching the
    // cursor and not a number.
    let size = header
    if size == 0 || data.length() < 1 + size {
      raise @moonzip.Truncated(at=data.length())
    }
    let block = data[1:1 + size]
    used = 1 + size
    let (dist, header_bytes) = Dist::read(block)
    if dist.log > 6 {
      raise @moonzip.Header(at=0, what="a weight table scaled past six bits")
    }
    let table = Table::build(dist)
    let bits = Rev::new(block[header_bytes:])
    let mut state1 = table.initial(bits)
    let mut state2 = table.initial(bits)
    let mut running = true
    while running {
      weights.push(table.symbol(state1))
      state1 = table.baseline[state1] + bits.take_or_zero(table.nb_bits[state1])
      if bits.left() <= 0 {
        weights.push(table.symbol(state2))
        running = false
        break
      }
      weights.push(table.symbol(state2))
      state2 = table.baseline[state2] + bits.take_or_zero(table.nb_bits[state2])
      if bits.left() <= 0 {
        weights.push(table.symbol(state1))
        running = false
        break
      }
      if weights.length() >= 255 {
        running = false
      }
    }
  }
  (Tree::from_weights(weights), used)
}

///|
/// Complete the weight series and turn it into code lengths.
fn Tree::from_weights(weights : Array[Int32]) -> Tree raise @moonzip.Refused {
  if weights.length() == 0 {
    raise @moonzip.Header(at=0, what="a Huffman tree with no symbols")
  }
  let mut total = 0
  for w in weights {
    if w > 11 {
      raise @moonzip.Header(at=0, what="a Huffman weight past eleven bits")
    }
    if w > 0 {
      total += 1 << (w - 1)
    }
  }
  // The last symbol's weight is whatever completes the total to a power of two,
  // and that power is the tree's depth.
  let mut target = 1
  while target <= total {
    target = target << 1
  }
  let missing = target - total
  let mut last = 0
  while 1 << last < missing {
    last += 1
  }
  if 1 << last != missing {
    raise @moonzip.Header(at=0, what="a Huffman tree that cannot be completed")
  }
  let full : Array[Int32] = []
  for w in weights {
    full.push(w)
  }
  full.push(last + 1)
  let max_bits = highbit(target)
  let lengths = Array::make(full.length(), 0)
  let mut any_one = false
  for s in 0..<full.length() {
    let w = full[s]
    lengths[s] = if w > 0 { max_bits + 1 - w } else { 0 }
    if w == 1 {
      any_one = true
    }
  }
  if !any_one {
    raise @moonzip.Header(
      at=0,
      what="a Huffman tree with no least-frequent symbol",
    )
  }
  // Symbols in (length, symbol) order, and where each length band begins.
  let ordered : Array[Int32] = []
  let start = Array::make(max_bits + 2, 0)
  let count = Array::make(max_bits + 2, 0)
  for len in 1..<=max_bits {
    start[len] = ordered.length()
    for s in 0..<full.length() {
      if lengths[s] == len {
        ordered.push(s)
        count[len] += 1
      }
    }
  }
  start[max_bits + 1] = ordered.length()
  // Codes are handed out from the *longest* length down, each band starting at
  // half of where the previous one ended. That is what makes a shorter code
  // numerically greater, and therefore what lets the decoder pick a length by
  // reading bits from the top.
  let first_code = Array::make(max_bits + 2, 0)
  let mut width = max_bits
  let mut code = 0
  while width >= 1 {
    first_code[width] = code
    code = (code + count[width]) >> 1
    width -= 1
  }
  { ordered, start, count, first_code, max_bits, }
}

///|
/// One symbol, read from the bitstream.
fn Tree::read_symbol(self : Tree, bits : Rev) -> Int32 raise @moonzip.Refused {
  let mut code = 0
  let mut width = 1
  while width <= self.max_bits {
    code = (code << 1) | bits.take(1)
    let base = self.first_code[width]
    if code >= base && code < base + self.count[width] {
      return self.ordered[self.start[width] + code - base]
    }
    width += 1
  }
  raise @moonzip.Code(at=0)
}

///|
/// A run of literal bytes, decoded from one of the streams of a literals section.
fn decode_literals(
  section : BytesView,
  count : Int32,
  tree : Tree,
) -> Bytes raise @moonzip.Refused {
  let bits = Rev::new(section)
  let out : Array[Byte] = []
  for _ in 0..<count {
    out.push(tree.read_symbol(bits).to_byte())
  }
  Bytes::from_array(out)
}
