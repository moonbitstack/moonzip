// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A small deterministic generator, so a failing case is reproducible.
fn lcg(state : Int32) -> Int32 {
  (state * 1103515245 + 12345) & 0x7FFFFFFF
}

///|
/// Frequencies that look like real data: a few common symbols and a long tail,
/// which is the shape that produces deep codes and exercises the length limit.
fn skewed_freq(n : Int32, seed : Int32) -> FixedArray[Int32] {
  let freq = FixedArray::make(n, 0)
  let mut state = seed
  for i in 0..<n {
    state = lcg(state)
    // Every symbol is possible, but the chance falls off steeply with index.
    let weight = 1 + (state >> 20) % (1 + 4096 / (1 + i))
    freq[i] = weight
  }
  freq
}

///|
/// The writer and the reader have to agree on the canonical code for every
/// symbol, at every width, in every spelling of the tree. They did not the first
/// time: the writer assigned widths by frequency and the simple form assigns them
/// by position, and the two only disagree with exactly three symbols — which is
/// why this test walks alphabet sizes past four.
test "prefix codes survive their own round trip" {
  for n in [2, 3, 4, 5, 6, 7, 8, 16, 26, 64, 256, 704] {
    let freq = skewed_freq(n, n * 7919)
    let tree = Tree::of(freq, 15)
    let w = Writer::new()
    write_prefix(w, tree.widths, n)
    let order = FixedArray::make(400, 0)
    let mut state = n
    for i in 0..<400 {
      state = lcg(state)
      let mut symbol = state % n
      // Half the symbols are drawn from the live ones, which keeps the test
      // honest about widths rather than about the histogram.
      while tree.widths[symbol] == 0 {
        symbol = (symbol + 1) % n
      }
      order[i] = symbol
      tree.write(w, symbol)
    }
    let data = w.finish()
    let bits = Bits::new(data)
    let code = read_prefix(bits, n, n)
    for i in 0..<400 {
      let got = code.read(bits)
      if got != order[i] {
        fail(
          "alphabet \{n}: symbol \{i} read back as \{got}, wrote \{order[i]}",
        )
      }
    }
  }
}

///|
/// The same for the extremes the format allows: one symbol, and every symbol at
/// the maximum width.
test "degenerate alphabets survive their own round trip" {
  let one = FixedArray::make(256, 0)
  one[200] = 5
  let tree = Tree::of(one, 15)
  let w = Writer::new()
  write_prefix(w, tree.widths, 256)
  tree.write(w, 200)
  let bits = Bits::new(w.finish())
  let code = read_prefix(bits, 256, 256)
  for _ in 0..<10 {
    if code.read(bits) != 200 {
      fail("a one-symbol code did not read back as its symbol")
    }
  }

  let flat = FixedArray::make(256, 1)
  let tree = Tree::of(flat, 15)
  let w2 = Writer::new()
  write_prefix(w2, tree.widths, 256)
  for i in 0..<256 {
    tree.write(w2, i)
  }
  let bits2 = Bits::new(w2.finish())
  let code2 = read_prefix(bits2, 256, 256)
  for i in 0..<256 {
    if code2.read(bits2) != i {
      fail("an eight-bit-wide alphabet did not read back at symbol \{i}")
    }
  }
}

///|
/// The command table is built from arithmetic, and its inverse from more
/// arithmetic. Every one of the 576 (insert code, copy code) pairs has to land on
/// a symbol that names it back.
test "the command table inverts" {
  let mut failures = 0
  for insert_code in 0..<24 {
    for copy_code in 0..<24 {
      let symbol = command_code(insert_code, copy_code)
      let cmd = cmd_lut[symbol]
      let insert = offsets_of(insert_bits, 0)[insert_code]
      let copy = offsets_of(copy_bits, 2)[copy_code]
      if cmd.insert != insert ||
        cmd.copy != copy ||
        cmd.insert_bits != insert_bits[insert_code] ||
        cmd.copy_bits != copy_bits[copy_code] {
        failures += 1
      }
    }
  }
  if failures > 0 {
    fail("\{failures} of 576 command symbols do not name their pair")
  }
}

///|
/// The distance ladder has to cover every distance exactly once, with the number
/// of extra bits the reader will expect.
test "the distance ladder is invertible" {
  let codes = distances(0, 0, 64)
  let mut distance = 1
  while distance < 300000 {
    let (code, extra, value) = codes.code(distance)
    if code < 16 || code >= 64 {
      fail("distance \{distance} landed on code \{code}")
    }
    if codes.offset[code] + (value << codes.npostfix) != distance {
      fail("distance \{distance} does not round trip through code \{code}")
    }
    if value >= 1 << extra && extra > 0 {
      fail("distance \{distance}: \{value} does not fit in \{extra} bits")
    }
    distance += if distance < 100 { 1 } else { 997 }
  }
}

///|
/// A body long enough to need several meta-blocks, written with a small block
/// size so the test does not have to be sixteen megabytes long. Each block
/// re-reads its own three trees and its own headers; the "another follows" bit is
/// the one place a writer can go wrong and still look right on one block.
test "many meta-blocks, one stream" {
  let body : Array[Byte] = []
  for i in 0..<9000 {
    body.push((97 + i % 26).to_byte())
    if i % 7 == 0 {
      body.push(b' ')
    }
  }
  let source = Bytes::from_array(body)
  for block in [64, 1000, 4096] {
    let packed = compress(source[:], 16, block)
    let back = unbrotli(packed[:])
    if back != source {
      fail(
        "block \{block}: \{back.length()} bytes back, not \{source.length()}",
      )
    }
  }
}
