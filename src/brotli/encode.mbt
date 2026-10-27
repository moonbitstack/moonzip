// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A prefix code the writer has decided on: the widths, the canonical codes, and
/// whether the whole alphabet is one symbol.
///
/// The last flag is not a micro-optimisation. A one-symbol code written in the
/// simple form consumes **no bits** — the reference builds a table entry with
/// width zero — so a writer that still writes a width-one code puts one bit in
/// the stream the reader will not take, and everything after it is garbage.
priv struct Tree {
  widths : FixedArray[Int32]
  codes : FixedArray[Int32]
  single : Bool
}

///|
fn Tree::of(freq : FixedArray[Int32], limit : Int32) -> Tree {
  let widths = code_lengths(freq, limit)
  let used : Array[Int32] = []
  for i in 0..<widths.length() {
    if widths[i] > 0 {
      used.push(i)
    }
  }
  // The simple form does not transmit widths: the reader derives them from the
  // *number* of symbols, and always hands the shortest one to the symbol it read
  // first. A writer that keeps the widths its own Huffman tree chose disagrees
  // with that as soon as the shortest symbol is not the lowest-numbered one —
  // and with four symbols it disagrees about all of them. So the simple spellings
  // are normalised here, once, for both sides.
  if used.length() == 0 {
    // An alphabet nothing uses still needs a code, because the format always
    // reads three of them.
    widths[0] = 1
    used.push(0)
  } else if used.length() == 2 {
    widths[used[0]] = 1
    widths[used[1]] = 1
  } else if used.length() == 3 {
    widths[used[0]] = 1
    widths[used[1]] = 2
    widths[used[2]] = 2
  } else if used.length() == 4 {
    for i in 0..<4 {
      widths[used[i]] = 2
    }
  }
  {
    widths,
    codes: canonical_codes(widths, widths.length()),
    single: used.length() == 1,
  }
}

///|
fn Tree::write(self : Tree, w : Writer, symbol : Int32) -> Unit {
  if self.single {
    return
  }
  write_code(w, self.widths, self.codes, symbol)
}

///|
/// One command: literals to copy verbatim, then a backward reference.
priv struct Step {
  insert : Int32
  copy : Int32
  distance : Int32
}

///|
/// The window size, in the format's own encoding: 16 is a single zero bit, 17 is
/// three zeros, and everything else is a small offset from 8 or 17.
fn write_window(w : Writer, size : Int32) -> Unit {
  if size == 16 {
    w.put(0, 1)
  } else if size >= 18 {
    w.put(1, 1)
    w.put(size - 17, 3)
  } else if size == 17 {
    w.put(1, 1)
    w.put(0, 3)
    w.put(0, 3)
  } else {
    w.put(1, 1)
    w.put(0, 3)
    w.put(size - 8, 3)
  }
}

///|
/// One compressed meta-block over `data[at ..< at + span)`.
fn write_block(
  w : Writer,
  data : BytesView,
  at : Int32,
  span : Int32,
  reach : Int32,
  table : FixedArray[Int32],
  chain : FixedArray[Int32],
) -> Unit {
  let steps = parse(data, at, span, reach, table, chain)
  let literals = FixedArray::make(256, 0)
  let commands = FixedArray::make(704, 0)
  let offsets = FixedArray::make(64, 0)
  let insert_offsets = offsets_of(insert_bits, 0)
  let copy_offsets = offsets_of(copy_bits, 2)
  let distance_codes = distances(0, 0, 64)
  let mut tail = span
  let mut cursor = at
  for step in steps {
    let (insert_code, _) = length_code(insert_offsets, step.insert)
    let (copy_code, _) = length_code(copy_offsets, step.copy)
    commands[command_code(insert_code, copy_code)] += 1
    let (code, _, _) = distance_codes.code(step.distance)
    offsets[code] += 1
    for i in 0..<step.insert {
      literals[data[cursor + i].to_int()] += 1
    }
    cursor += step.insert + step.copy
    tail -= step.insert + step.copy
  }
  for i in 0..<tail {
    literals[data[cursor + i].to_int()] += 1
  }
  // The tail command is part of the stream like any other, so it has to be in
  // the histogram. Leaving it out produced a stream whose command tree held a
  // single symbol that was not the one the tail used — a bug that only appears
  // when a block ends on a literal run, which is to say every small input.
  if tail > 0 {
    let (insert_code, _) = length_code(insert_offsets, tail)
    let (copy_code, _) = length_code(copy_offsets, 2)
    commands[command_code(insert_code, copy_code)] += 1
  }
  let literal_tree = Tree::of(literals, 15)
  let command_tree = Tree::of(commands, 15)
  let distance_tree = Tree::of(offsets, 15)

  w.put(0, 1) // not the last meta-block
  let nibbles = nibble_count(span)
  w.put(nibbles - 4, 2)
  let stored = span - 1
  for i in 0..<nibbles {
    w.put((stored >> (i * 4)) & 0xF, 4)
  }
  w.put(0, 1) // compressed, not stored
  for _ in 0..<3 {
    w.put(0, 1) // one block type per stream
  }
  w.put(0, 6) // NPOSTFIX 0, NDIRECT 0
  w.put(0, 2) // context mode LSB6 for the one literal block type
  w.put(0, 1) // one literal code everywhere
  w.put(0, 1) // one distance code everywhere
  write_prefix(w, literal_tree.widths, 256)
  write_prefix(w, command_tree.widths, 704)
  write_prefix(w, distance_tree.widths, 64)
  cursor = at
  for step in steps {
    let (insert_code, insert_extra) = length_code(insert_offsets, step.insert)
    let (copy_code, copy_extra) = length_code(copy_offsets, step.copy)
    command_tree.write(w, command_code(insert_code, copy_code))
    w.put(insert_extra, insert_bits[insert_code])
    w.put(copy_extra, copy_bits[copy_code])
    for i in 0..<step.insert {
      literal_tree.write(w, data[cursor + i].to_int())
    }
    cursor += step.insert
    let (code, extra, value) = distance_codes.code(step.distance)
    distance_tree.write(w, code)
    w.put(value, extra)
    cursor += step.copy
  }
  // The tail: literals up to the end of the meta-block, and a copy that is never
  // performed because the length runs out first. When there is no tail the last
  // real command already finished the block, and writing this command anyway
  // would leave its symbol in the stream for the *next* meta-block to read.
  if tail > 0 {
    let (insert_code, insert_extra) = length_code(insert_offsets, tail)
    let (copy_code, _) = length_code(copy_offsets, 2)
    command_tree.write(w, command_code(insert_code, copy_code))
    w.put(insert_extra, insert_bits[insert_code])
    for i in 0..<tail {
      literal_tree.write(w, data[cursor + i].to_int())
    }
  }
}

///|
/// How many four-bit groups a meta-block length needs: at least four, and the top
/// group must be non-zero, or the reader rejects the padding.
fn nibble_count(length : Int32) -> Int32 {
  let mut nibbles = 4
  while nibbles < 7 && length - 1 >= 1 << (nibbles * 4) {
    nibbles += 1
  }
  nibbles
}

///|
/// Greedy LZ77 over a hash chain, four bytes hashed to 16 bits.
///
/// The chain is what makes the difference between "finds the repeats in a line"
/// and "finds the repeats in a file": a single hash slot always returns the most
/// recent occurrence of a four-byte prefix, which on periodic text is the worst
/// one — 46 bytes back instead of 11,546. Walking a handful of candidates costs a
/// few comparisons and finds the long match.
///
/// `chain` is a ring over the last `CHAIN_SIZE` positions, shared across
/// meta-blocks so that a match can reach into the previous one; a stale entry is
/// caught by the distance check, not by clearing the table.
const CHAIN_SIZE : Int32 = 1 << 20

///|
/// How many candidates to walk before settling for the best so far. 256 is where
/// the ratio stops moving on periodic text — at 46-byte spacing, the long match
/// lives 251 entries down the chain and 64 never reaches it.
const CHAIN_DEPTH : Int32 = 256

///|
/// Stop walking once a match this long is in hand. Past it the extra bits a
/// longer match saves are smaller than the time spent looking for one.
const NICE_LENGTH : Int32 = 4096

///|
fn chain_size() -> Int32 {
  CHAIN_SIZE
}

///|
fn parse(
  data : BytesView,
  at : Int32,
  span : Int32,
  reach : Int32,
  table : FixedArray[Int32],
  chain : FixedArray[Int32],
) -> Array[Step] {
  let steps : Array[Step] = []
  let end = at + span
  let mask = CHAIN_SIZE - 1
  let mut cursor = at
  let mut literal_start = at
  while cursor + 4 <= end {
    let hash = hash_at(data, cursor)
    let (length, distance) = search(
      data,
      cursor,
      end,
      reach,
      table[hash],
      chain,
      mask,
    )
    record(cursor, hash, table, chain, mask)
    if length < 4 {
      cursor += 1
      continue
    }
    // One step of lazy matching: if the next position matches two bytes longer,
    // this byte is better spent as a literal. It costs one extra probe and pays
    // for itself on almost every text file.
    if cursor + 5 <= end {
      let next = table[hash_at(data, cursor + 1)]
      let (other, _) = search(data, cursor + 1, end, reach, next, chain, mask)
      if other > length + 1 {
        cursor += 1
        continue
      }
    }
    steps.push({ insert: cursor - literal_start, copy: length, distance, })
    let stop = cursor + length
    let mut fill = cursor + 1
    while fill + 4 <= stop {
      let h = hash_at(data, fill)
      record(fill, h, table, chain, mask)
      fill += 1
    }
    cursor = stop
    literal_start = cursor
  }
  steps
}

///|
/// Put `pos` at the head of its hash chain, remembering the previous head.
fn record(
  pos : Int32,
  hash : Int32,
  table : FixedArray[Int32],
  chain : FixedArray[Int32],
  mask : Int32,
) -> Unit {
  chain[pos & mask] = table[hash]
  table[hash] = pos
}

///|
/// The longest match for `pos` among the chain's candidates, and its distance.
fn search(
  data : BytesView,
  pos : Int32,
  end : Int32,
  reach : Int32,
  start : Int32,
  chain : FixedArray[Int32],
  mask : Int32,
) -> (Int32, Int32) {
  let limit = if end - pos > 65536 { 65536 } else { end - pos }
  let mut best = 0
  let mut distance = 0
  let mut candidate = start
  let mut depth = 0
  while candidate >= 0 && depth < CHAIN_DEPTH {
    let away = pos - candidate
    if away <= 0 || away > reach {
      break
    }
    // Someone else's business: if the byte just past the best match so far does
    // not repeat, no candidate can beat it.
    if best == 0 || data[candidate + best] == data[pos + best] {
      let mut length = 0
      while length < limit && data[candidate + length] == data[pos + length] {
        length += 1
      }
      if length > best {
        best = length
        distance = away
        if best >= limit || best >= NICE_LENGTH {
          break
        }
      }
    }
    candidate = chain[candidate & mask]
    depth += 1
  }
  (best, distance)
}

///|
fn hash_at(data : BytesView, at : Int32) -> Int32 {
  let mut value = data[at].to_int()
  value = (value << 8) | data[at + 1].to_int()
  value = (value << 8) | data[at + 2].to_int()
  value = (value << 8) | data[at + 3].to_int()
  ((value * 0x1E35A7BD) >> 8) & 0xFFFF
}
