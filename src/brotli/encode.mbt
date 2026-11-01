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
  /// The dictionary address this copy refers to, or -1 for an ordinary
  /// back-reference. A dictionary copy's distance is not known until the writer
  /// reaches it, because it is measured from how much output exists by then.
  dict : Int32
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
  depth : Int32,
  lazymatch : Bool,
  split : Bool,
  contexts : Bool,
  dictionary : Bool,
) -> Unit {
  let steps = parse(
    data, at, span, reach, table, chain, depth, lazymatch, dictionary,
  )
  let insert_offsets = offsets_of(insert_bits, 0)
  let copy_offsets = offsets_of(copy_bits, 2)
  let distance_codes = distances(0, 0, 64)
  // How much of the block is a trailing literal run, which is its own command.
  let mut tail = span
  for step in steps {
    tail -= step.insert + step.copy
  }
  let mode = if contexts { choose_mode(data, at, span) } else { 0 }
  // The command stream, in order. It is built before the histograms because the
  // split search walks it twice: once to find where the cut pays, and once to
  // count each half.
  let total_cmds = steps.length() + (if tail > 0 { 1 } else { 0 })
  let codes = FixedArray::make(if total_cmds > 0 { total_cmds } else { 1 }, 0)
  let literals = FixedArray::make(256, 0)
  // Literals counted per context: which of the 64 sub-alphabets each one falls in,
  // decided by the two bytes before it. Only filled when the block models them.
  let ctx_hist = FixedArray::make(if contexts { 64 * 256 } else { 256 }, 0)
  let offsets = FixedArray::make(64, 0)
  let mut cursor = at
  let mut index = 0
  for step in steps {
    let (insert_code, _) = length_code(insert_offsets, step.insert)
    let (copy_code, _) = length_code(copy_offsets, step.copy)
    codes[index] = command_code(insert_code, copy_code)
    let (dcode, _, _) = distance_codes.code(
      step_distance(step, cursor + step.insert, reach),
    )
    offsets[dcode] += 1
    for i in 0..<step.insert {
      let byte = data[cursor + i].to_int()
      literals[byte] += 1
      if contexts {
        let before = if cursor + i > 0 {
          data[cursor + i - 1].to_int()
        } else {
          0
        }
        let further = if cursor + i > 1 {
          data[cursor + i - 2].to_int()
        } else {
          0
        }
        ctx_hist[context_id(mode, before, further) * 256 + byte] += 1
      }
    }
    cursor += step.insert + step.copy
    index += 1
  }
  for i in 0..<tail {
    let byte = data[cursor + i].to_int()
    literals[byte] += 1
    if contexts {
      let before = if cursor + i > 0 {
        data[cursor + i - 1].to_int()
      } else {
        0
      }
      let further = if cursor + i > 1 {
        data[cursor + i - 2].to_int()
      } else {
        0
      }
      ctx_hist[context_id(mode, before, further) * 256 + byte] += 1
    }
  }
  // The tail command is part of the stream like any other, so it has to be in
  // the histogram of whichever half it falls in. Leaving it out produced a stream
  // whose command tree held a single symbol that was not the one the tail used —
  // a bug that only appears when a block ends on a literal run, which is to say
  // every small input.
  if tail > 0 {
    let (insert_code, _) = length_code(insert_offsets, tail)
    let (copy_code, _) = length_code(copy_offsets, 2)
    codes[index] = command_code(insert_code, copy_code)
  }
  // Block splitting: the command stream may be cut in two, each half carrying its
  // own prefix code. Where the cut falls is the only choice the format leaves
  // open, and it is a real choice — a cut that saves data bits but pays for a
  // second tree is a loss, so the search weighs both.
  let cut = if split && total_cmds >= 2 {
    best_cut(codes, total_cmds)
  } else {
    total_cmds
  }
  let split_here = cut < total_cmds
  let commands0 = FixedArray::make(704, 0)
  let commands1 = FixedArray::make(704, 0)
  for i in 0..<total_cmds {
    if i < cut {
      commands0[codes[i]] += 1
    } else {
      commands1[codes[i]] += 1
    }
  }
  // Literal codes. One code for the whole alphabet is what every writer before
  // this one did; the context model asks instead which of 64 sub-alphabets each
  // literal falls in and groups those that want the same code, refusing the whole
  // exercise when a second code does not pay for its description.
  let (lit_codes, lit_map) = if contexts {
    group_contexts(ctx_hist)
  } else {
    (1, FixedArray::make(64, 0))
  }
  let lit_trees : Array[Tree] = []
  if lit_codes <= 1 {
    lit_trees.push(Tree::of(literals, 15))
  } else {
    for g in 0..<lit_codes {
      lit_trees.push(Tree::of(cluster_hist(ctx_hist, lit_map, g), 15))
    }
  }
  let command_tree0 = Tree::of(commands0, 15)
  let mut command_tree1 = command_tree0
  if split_here {
    command_tree1 = Tree::of(commands1, 15)
  }
  let distance_tree = Tree::of(offsets, 15)
  // The two small trees a split needs: one over block types (the two explicit
  // ones, and the "recent" spellings the format also allows), and one over the
  // length ranges the format codes. A single-symbol size tree costs no bits for
  // its code, which is what `emit_block_len` guards.
  let type_widths = FixedArray::make(4, 0)
  type_widths[2] = 1
  type_widths[3] = 1
  let type_codes = canonical_codes(type_widths, 4)
  let (c0, b0, e0) = block_len_code(cut)
  let (c1, b1, e1) = block_len_code(total_cmds - cut)
  let size_widths = FixedArray::make(26, 0)
  size_widths[c0] = 1
  size_widths[c1] = 1
  let size_single = c0 == c1
  let size_codes = canonical_codes(size_widths, 26)

  w.put(0, 1) // not the last meta-block
  let nibbles = nibble_count(span)
  w.put(nibbles - 4, 2)
  let stored = span - 1
  for i in 0..<nibbles {
    w.put((stored >> (i * 4)) & 0xF, 4)
  }
  w.put(0, 1) // compressed, not stored
  w.put(0, 1) // literals: one block type
  if split_here {
    w.put(1, 1) // commands: two block types
    w.put(0, 3)
    write_prefix(w, type_widths, 4)
    write_prefix(w, size_widths, 26)
    emit_block_len(w, size_widths, size_codes, size_single, c0, b0, e0)
  } else {
    w.put(0, 1) // commands: one block type
  }
  w.put(0, 1) // distances: one block type
  w.put(0, 6) // NPOSTFIX 0, NDIRECT 0
  w.put(mode, 2) // context mode for the one literal block type
  if lit_codes <= 1 {
    w.put(0, 1) // one literal code everywhere
  } else {
    write_count(w, lit_codes - 1)
    w.put(0, 1) // the map has no run-length escape
    let map_hist = FixedArray::make(lit_codes, 0)
    for c in 0..<64 {
      map_hist[lit_map[c]] += 1
    }
    let map_tree = Tree::of(map_hist, 15)
    write_prefix(w, map_tree.widths, lit_codes)
    for c in 0..<64 {
      map_tree.write(w, lit_map[c])
    }
    w.put(0, 1) // the map is not move-to-front coded
  }
  w.put(0, 1) // one distance code everywhere
  for t in lit_trees {
    write_prefix(w, t.widths, 256)
  }
  write_prefix(w, command_tree0.widths, 704)
  if split_here {
    write_prefix(w, command_tree1.widths, 704)
  }
  write_prefix(w, distance_tree.widths, 64)
  cursor = at
  index = 0
  for step in steps {
    if split_here && index == cut {
      write_code(w, type_widths, type_codes, 3)
      emit_block_len(w, size_widths, size_codes, size_single, c1, b1, e1)
    }
    let (insert_code, insert_extra) = length_code(insert_offsets, step.insert)
    let (copy_code, copy_extra) = length_code(copy_offsets, step.copy)
    let tree = if split_here && index >= cut {
      command_tree1
    } else {
      command_tree0
    }
    tree.write(w, command_code(insert_code, copy_code))
    w.put(insert_extra, insert_bits[insert_code])
    w.put(copy_extra, copy_bits[copy_code])
    for i in 0..<step.insert {
      let byte = data[cursor + i].to_int()
      if lit_codes <= 1 {
        lit_trees[0].write(w, byte)
      } else {
        let before = if cursor + i > 0 {
          data[cursor + i - 1].to_int()
        } else {
          0
        }
        let further = if cursor + i > 1 {
          data[cursor + i - 2].to_int()
        } else {
          0
        }
        lit_trees[lit_map[context_id(mode, before, further)]].write(w, byte)
      }
    }
    cursor += step.insert
    let (code, extra, value) = distance_codes.code(
      step_distance(step, cursor, reach),
    )
    distance_tree.write(w, code)
    w.put(value, extra)
    cursor += step.copy
    index += 1
  }
  // The tail: literals up to the end of the meta-block, and a copy that is never
  // performed because the length runs out first. When there is no tail the last
  // real command already finished the block, and writing this command anyway
  // would leave its symbol in the stream for the *next* meta-block to read.
  if tail > 0 {
    if split_here && steps.length() == cut {
      write_code(w, type_widths, type_codes, 3)
      emit_block_len(w, size_widths, size_codes, size_single, c1, b1, e1)
    }
    let (insert_code, insert_extra) = length_code(insert_offsets, tail)
    let (copy_code, _) = length_code(copy_offsets, 2)
    let tree = if split_here && steps.length() >= cut {
      command_tree1
    } else {
      command_tree0
    }
    tree.write(w, command_code(insert_code, copy_code))
    w.put(insert_extra, insert_bits[insert_code])
    for i in 0..<tail {
      let byte = data[cursor + i].to_int()
      if lit_codes <= 1 {
        lit_trees[0].write(w, byte)
      } else {
        let before = if cursor + i > 0 {
          data[cursor + i - 1].to_int()
        } else {
          0
        }
        let further = if cursor + i > 1 {
          data[cursor + i - 2].to_int()
        } else {
          0
        }
        lit_trees[lit_map[context_id(mode, before, further)]].write(w, byte)
      }
    }
  }
}

///|
/// The bits a code description costs, measured rather than estimated.
///
/// Writing the candidate to a throwaway writer and counting what it put there is
/// both exact and cheap — a few hundred bits — and it is what makes the two
/// searches honest. An estimate of "so much per used symbol" is wrong by enough
/// that it accepts splits which then come out larger than the stream they were
/// supposed to shrink.
fn tree_bits(widths : FixedArray[Int32], alphabet : Int32) -> Int32 {
  let w = Writer::new()
  write_prefix(w, widths, alphabet)
  w.count()
}

///|
/// The bits a histogram spends under the code built from it.
///
/// A single-symbol code spends no data bits at all — the reader gets the symbol
/// from the block type and reads nothing — so the whole cost is its description.
fn tree_cost(
  counts : FixedArray[Int32],
  tree : Tree,
  alphabet : Int32,
) -> Int32 {
  let description = tree_bits(tree.widths, alphabet)
  if tree.single {
    return description
  }
  let mut bits = 0
  for i in 0..<counts.length() {
    bits += counts[i] * tree.widths[i]
  }
  bits + description
}

///|
/// Where to cut the command stream, or its length when no cut pays.
///
/// A split only earns its second tree when the two halves are different kinds of
/// command stream — a run of small copies followed by a run of long ones, say. So
/// this compares a single code against sampled cuts and keeps the best only if it
/// beats not splitting at all. The sample is coarse on purpose: the cost curve is
/// smooth, and building two codes at every one of a hundred thousand positions
/// would make quality eleven quadratic in the block size.
fn best_cut(codes : FixedArray[Int32], total : Int32) -> Int32 {
  let whole = FixedArray::make(704, 0)
  for i in 0..<total {
    whole[codes[i]] += 1
  }
  let whole_tree = Tree::of(whole, 15)
  let mut best_cost = tree_cost(whole, whole_tree, 704)
  let left = FixedArray::make(704, 0)
  let right = FixedArray::make(704, 0)
  for i in 0..<total {
    right[codes[i]] += 1
  }
  let stride = if total > 64 { total / 64 } else { 1 }
  let mut best = total
  let mut at = 1
  while at < total {
    let moved = codes[at - 1]
    left[moved] += 1
    right[moved] -= 1
    // Nothing useful lives near either end: a cut there is one code plus a stub.
    if (at % stride == 0 || at == total - 1) &&
      at >= stride / 2 &&
      total - at >= stride / 2 {
      let ltree = Tree::of(left, 15)
      let rtree = Tree::of(right, 15)
      let cost = tree_cost(left, ltree, 704) + tree_cost(right, rtree, 704)
      if cost < best_cost {
        best_cost = cost
        best = at
      }
    }
    at += 1
  }
  best
}

///|
/// The distance a step's copy is written with.
///
/// A back-reference carries its own. A dictionary reference is measured from the
/// bytes that exist when the copy happens, which is `(emitted, window)` with one
/// added to tell the reader "past the window" and the address above that — so the
/// same step has no fixed distance until the writer reaches it.
fn step_distance(step : Step, emitted : Int32, reach : Int32) -> Int32 {
  if step.dict < 0 {
    return step.distance
  }
  let now = if emitted < reach { emitted } else { reach }
  now + 1 + step.dict
}

///|
/// Write a count of block types or context codes, the inverse of `read_count`.
///
/// Zero is one bit. Everything else is a length prefix and a payload: one, then
/// three bits naming how many payload bits follow. The payload is the value with
/// its top bit removed, so each width covers a doubling.
fn write_count(w : Writer, value : Int32) -> Unit {
  if value == 0 {
    w.put(0, 1)
    return
  }
  w.put(1, 1)
  if value == 1 {
    w.put(0, 3)
    return
  }
  let mut width = 1
  while 1 << (width + 1) <= value {
    width += 1
  }
  w.put(width, 3)
  w.put(value - (1 << width), width)
}

///|
/// The length-range code and extra bits for a block length, the inverse of what
/// the reader does with `block_len_offset` and `block_len_bits`.
fn block_len_code(len : Int32) -> (Int32, Int32, Int32) {
  for c in 0..<26 {
    let lo = block_len_offset[c]
    if len >= lo && len < lo + (1 << block_len_bits[c]) {
      return (c, block_len_bits[c], len - lo)
    }
  }
  (25, block_len_bits[25], len - block_len_offset[25])
}

///|
/// Write a block length under a size tree that may be a single symbol, in which
/// case the reader assigns it width zero and the code itself costs no bits.
fn emit_block_len(
  w : Writer,
  widths : FixedArray[Int32],
  codes : FixedArray[Int32],
  single : Bool,
  c : Int32,
  bits : Int32,
  extra : Int32,
) -> Unit {
  if !single {
    write_code(w, widths, codes, c)
  }
  w.put(extra, bits)
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
  depth : Int32,
  lazymatch : Bool,
  dictionary : Bool,
) -> Array[Step] {
  let steps : Array[Step] = []
  let end = at + span
  let mask = CHAIN_SIZE - 1
  let words = if dictionary { Some(DictIndex::build()) } else { None }
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
      depth,
    )
    record(cursor, hash, table, chain, mask)
    // A dictionary word is worth taking over a back-reference when it is longer,
    // and it needs no lazy step: a back-reference a byte later cannot be longer
    // than the longest word the format can name.
    match words {
      Some(index) => {
        let (word_len, slot, transform) = index.find(data, cursor, end)
        if word_len > length {
          steps.push({
            insert: cursor - literal_start,
            copy: word_len,
            distance: 0,
            dict: DictIndex::address(word_len, slot, transform),
          })
          let stop = cursor + word_len
          let mut fill = cursor + 1
          while fill + 4 <= stop {
            let h = hash_at(data, fill)
            record(fill, h, table, chain, mask)
            fill += 1
          }
          cursor = stop
          literal_start = cursor
          continue
        }
      }
      None => ()
    }
    if length < 4 {
      cursor += 1
      continue
    }
    // One step of lazy matching: if the next position matches two bytes longer,
    // this byte is better spent as a literal. It costs one extra probe and pays
    // for itself on almost every text file, so only the lowest qualities skip it.
    if lazymatch && cursor + 5 <= end {
      let next = table[hash_at(data, cursor + 1)]
      let (other, _) = search(
        data,
        cursor + 1,
        end,
        reach,
        next,
        chain,
        mask,
        depth,
      )
      if other > length + 1 {
        cursor += 1
        continue
      }
    }
    steps.push({
      insert: cursor - literal_start,
      copy: length,
      distance,
      dict: -1,
    })
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
  depth : Int32,
) -> (Int32, Int32) {
  let limit = if end - pos > 65536 { 65536 } else { end - pos }
  let mut best = 0
  let mut distance = 0
  let mut candidate = start
  let mut seen = 0
  while candidate >= 0 && seen < depth {
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
    seen += 1
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
