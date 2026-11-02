// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The optimal parse.
///
/// Greedy matching answers "what is the longest copy here" at every position it
/// lands on. That is not the same question as "what is the cheapest way to reach
/// the end of the block", and on text the two answers differ by a few per cent of
/// the output: a two-byte shorter copy that leaves a four-byte match one position
/// later is worth taking, and a copy at a distance that buys four more bytes is
/// often not worth taking at all.
///
/// This walks the block once from front to back, keeping for every position the
/// cheapest price of reaching it and the step that got there. The prices come from
/// the previous round's prefix codes, so the parse and the codes converge
/// together: a symbol the last round emitted often is cheap and gets chosen again,
/// one it never emitted is dear.
///
/// It is the same idea as the reference encoder's, with three differences that are
/// choices rather than oversights. The candidates at each position are the longest
/// match at each of a handful of distances rather than every match the hash chain
/// knows. The insert run a command carries is the one the cheapest path had, not a
/// state the search keeps. And a copy's distance is priced at the rate a repeat
/// costs rather than at the symbol it would need — see `copy_price`, where that
/// last one is the difference between 27,007 bytes and 26,113.
///
/// Every round is returned rather than only the last, and the caller encodes each
/// of them: a price list cannot see what the code descriptions cost, and the parse
/// that looks cheapest is not always the one that comes out smallest.

///|
/// How many candidate copies are kept at each position: the longest match among
/// the newest candidates, then the next longer one, and so on, each at the nearest
/// distance that reaches it. A longer match farther away and a shorter one close
/// by are the interesting pair, and the slots hold the walk between them. Six,
/// because the seventh and eighth changed the output by a byte.
const CANDIDATES : Int32 = 6

///|
/// The largest block the search will take, and the block size the caller splits
/// its input into at these qualities. The tables are about fifty bytes per input
/// byte — seven arrays of positions plus six candidates each — so a megabyte is
/// fifty megabytes, which is a compressor's budget and not a browser's.
const OPTIMAL_LIMIT : Int32 = 1 << 20

///|
/// The bits a copy's distance costs beyond a repeat's short code.
let repeat_extra : Int32 = 4

///|
/// The cheapest way to reach a position, as a price in sixteenths of a bit.
///
/// Four fractional bits, because the difference between two parses on a block of
/// a hundred kilobytes is a few hundred bits spread over a hundred thousand
/// decisions: integer bits round every one of them to the same value and the
/// search stops being able to tell two paths apart.
let price_scale : Int32 = 16

///|
/// What a symbol costs when the previous round's code has no width for it — the
/// round never emitted it. Not infinite: a parse that refuses to touch a symbol
/// the last round missed can never introduce one, and the first round of a block
/// would be fixed for good.
let unseen_price : Int32 = 15 * price_scale

///|
/// The prices one round of the search works from.
priv struct Prices {
  /// Per literal, indexed by context and byte: `64 * 256`.
  lit : FixedArray[Int32]
  /// The 704 command symbols.
  cmd : FixedArray[Int32]
  /// The 64 distance symbols.
  dist : FixedArray[Int32]
}

///|
/// The cheapest price of each symbol, from the codes the previous round's parse
/// produced.
///
/// This builds the same trees `write_block` will build — the same context
/// grouping, the same command alphabet — and reads the widths off them. An
/// estimate from -log2 of the frequency would be smoother, but it would also be a
/// different number than the one the block ends up paying, and the search only has
/// to be right about which of two steps is cheaper.
fn Prices::of(
  data : BytesView,
  at : Int32,
  span : Int32,
  steps : Array[Step],
  mode : Int32,
  contexts : Bool,
  insert_offsets : FixedArray[Int32],
  copy_offsets : FixedArray[Int32],
  distance_codes : Distances,
  reach : Int32,
) -> Prices {
  let ctx_hist = FixedArray::make(64 * 256, 0)
  let literals = FixedArray::make(256, 0)
  let lit_pos : Array[Int32] = []
  let offsets = FixedArray::make(64, 0)
  let ring = FixedArray::make(4, 0)
  ring[0] = 16
  ring[1] = 15
  ring[2] = 11
  ring[3] = 4
  let mut last = 0
  let mut cursor = at
  let mut tail = span
  for step in steps {
    tail -= step.insert + step.taken
  }
  let total_cmds = steps.length() + (if tail > 0 { 1 } else { 0 })
  let codes = FixedArray::make(if total_cmds > 0 { total_cmds } else { 1 }, 0)
  let mut index = 0
  for step in steps {
    let (insert_code, _) = length_code(insert_offsets, step.insert)
    let (copy_code, _) = length_code(copy_offsets, step.copy)
    let distance = step_distance(step, cursor + step.insert, reach)
    let mut dcode = short_distance_code(distance, ring, last)
    if dcode < 0 {
      let (code, _, _) = distance_codes.code(distance)
      dcode = code
    }
    let implicit = if dcode == 0 {
      implicit_command_code(insert_code, copy_code)
    } else {
      -1
    }
    codes[index] = if implicit >= 0 {
      implicit
    } else {
      command_code(insert_code, copy_code)
    }
    if implicit < 0 {
      offsets[dcode] += 1
    }
    last = remember_distance(distance, dcode, step.dict >= 0, ring, last)
    for i in 0..<step.insert {
      let byte = data[cursor + i].to_int()
      literals[byte] += 1
      ctx_hist[literal_context(data, cursor + i, mode) * 256 + byte] += 1
      lit_pos.push(cursor + i)
    }
    cursor += step.insert + step.taken
    index += 1
  }
  for i in 0..<tail {
    let byte = data[cursor + i].to_int()
    literals[byte] += 1
    ctx_hist[literal_context(data, cursor + i, mode) * 256 + byte] += 1
    lit_pos.push(cursor + i)
  }
  if tail > 0 {
    let (insert_code, _) = length_code(insert_offsets, tail)
    let (copy_code, _) = length_code(copy_offsets, 2)
    codes[index] = command_code(insert_code, copy_code)
  }
  let lit = build_literal_codes(
    ctx_hist, literals, lit_pos, data, mode, contexts, false,
  )
  let lit_price = FixedArray::make(64 * 256, unseen_price)
  for c in 0..<64 {
    let tree = lit.trees[lit.map[c]]
    for b in 0..<256 {
      let width = tree.widths[b]
      lit_price[c * 256 + b] = if width > 0 {
        width * price_scale
      } else if tree.single {
        // A sub-alphabet with one symbol in it spends nothing to say which.
        0
      } else {
        unseen_price
      }
    }
  }
  let command_counts = FixedArray::make(704, 0)
  for i in 0..<total_cmds {
    command_counts[codes[i]] += 1
  }
  let command_tree = Tree::of(command_counts, 15)
  let cmd_price = FixedArray::make(704, 0)
  for s in 0..<704 {
    let width = command_tree.widths[s]
    cmd_price[s] = if width > 0 {
      width * price_scale
    } else if command_tree.single {
      0
    } else {
      unseen_price
    }
  }
  let distance_tree = Tree::of(offsets, 15)
  let dist_price = FixedArray::make(64, 0)
  for s in 0..<64 {
    let width = distance_tree.widths[s]
    dist_price[s] = if width > 0 {
      width * price_scale
    } else if distance_tree.single {
      0
    } else {
      unseen_price
    }
  }
  { lit: lit_price, cmd: cmd_price, dist: dist_price, }
}

///|
/// Every match worth considering at every position, gathered in one pass.
///
/// The chain is walked newest-first, so a candidate that beats the best length so
/// far is also the cheapest one that reaches that far: the list of candidates at a
/// position is increasing in both length and distance. A copy shorter than the
/// next candidate's is then priced at the nearer distance, which is what makes the
/// list worth more than its first entry.
///
/// The dictionary is probed at the same time — once per position, because the
/// probe hashes four bytes and three case modes and is the most expensive thing
/// the writer does per byte. The greedy parse only pays for it where it lands;
/// this pays for it everywhere, which is most of what quality 11 costs.
fn gather(
  data : BytesView,
  at : Int32,
  span : Int32,
  reach : Int32,
  depth : Int32,
  dictionary : Bool,
  blen : FixedArray[Int32],
  bdist : FixedArray[Int32],
  dwlen : FixedArray[Int32],
  dtaken : FixedArray[Int32],
  daddr : FixedArray[Int32],
) -> Unit {
  let table = FixedArray::make(1 << 16, -1)
  let chain = FixedArray::make(span, -1)
  let end = at + span
  let words = if dictionary { Some(DictIndex::build()) } else { None }
  let mut pos = at
  while pos + 4 <= end {
    let slot = pos - at
    let hash = hash_at(data, pos)
    let limit = if end - pos > 65536 { 65536 } else { end - pos }
    let mut candidate = table[hash]
    let mut best = 3
    let mut bucket = 0
    let mut seen = 0
    while candidate >= 0 && seen < depth && bucket < CANDIDATES {
      let away = pos - candidate
      if away <= 0 || away > reach {
        break
      }
      // The byte past the best match so far decides whether this candidate can
      // beat it, before a single byte is compared.
      if data[candidate + best] == data[pos + best] {
        let mut length = 0
        while length < limit && data[candidate + length] == data[pos + length] {
          length += 1
        }
        if length > best {
          blen[slot * CANDIDATES + bucket] = length
          bdist[slot * CANDIDATES + bucket] = away
          bucket += 1
          best = length
          if best >= limit {
            break
          }
        }
      }
      candidate = chain[candidate - at]
      seen += 1
    }
    match words {
      Some(index) => {
        let (word_len, taken, which, transform) = index.find(data, pos, end)
        if taken >= 4 {
          dwlen[slot] = word_len
          dtaken[slot] = taken
          daddr[slot] = DictIndex::address(word_len, which, transform)
        }
      }
      None => ()
    }
    chain[slot] = table[hash]
    table[hash] = pos
    pos += 1
  }
}

///|
/// The price of a copy, given the number of literals since the last command.
///
/// The command symbol is exact — it is joint over the insert length and the copy
/// length, so a long insert run is dearer than a short one — and so are the extra
/// bits the two lengths carry.
///
/// The distance is not. It is priced at what a *repeat* costs: the short code for
/// "the distance before", which the command can often carry outright. Charging
/// each copy the width of the distance symbol it would need is the obvious model
/// and it is the wrong one, because it is self-fulfilling: a round that priced
/// fresh distances at ten bits finds a parse that uses fewer of them, the next
/// round's distance tree is flatter and prices them higher still, and the search
/// walks itself into a corner where almost nothing is a copy. Measured on this
/// repository's documentation, the exact model reaches 27,007 bytes and this one
/// 26,113 — the same corpus, the same search, three per cent apart.
///
/// Prices are in sixteenths of a bit. `repeat_extra` is what a distance the last
/// few copies did not use costs on top of a repeat.
fn copy_price(
  prices : Prices,
  insert_offsets : FixedArray[Int32],
  copy_offsets : FixedArray[Int32],
  insert : Int32,
  copy : Int32,
) -> Int32 {
  let (insert_code, _) = length_code(insert_offsets, insert)
  let (copy_code, _) = length_code(copy_offsets, copy)
  let extras = (insert_bits[insert_code] + copy_bits[copy_code]) * price_scale
  // "The distance before", carried by the command itself when the lengths allow
  // it: no distance symbol at all.
  let implicit = implicit_command_code(insert_code, copy_code)
  if implicit >= 0 {
    return prices.cmd[implicit] + extras
  }
  prices.cmd[command_code(insert_code, copy_code)] +
  prices.dist[0] +
  repeat_extra * price_scale +
  extras
}

///|
/// The cheapest way to reach every position of the block.
///
/// `advance` doubles as the record of what the step was — zero for a literal — and
/// the distance, dictionary address and word length sit beside it. There is no
/// separate "which candidate" array because the length is the candidate's, and a
/// back-reference of that length at that distance is the whole step.
fn choose(
  data : BytesView,
  at : Int32,
  span : Int32,
  mode : Int32,
  prices : Prices,
  blen : FixedArray[Int32],
  bdist : FixedArray[Int32],
  dwlen : FixedArray[Int32],
  dtaken : FixedArray[Int32],
  daddr : FixedArray[Int32],
  insert_offsets : FixedArray[Int32],
  copy_offsets : FixedArray[Int32],
  distance_codes : Distances,
  reach : Int32,
  best : FixedArray[Int32],
  advance : FixedArray[Int32],
  dist_at : FixedArray[Int32],
  dict_at : FixedArray[Int32],
  dcopy_at : FixedArray[Int32],
  run : FixedArray[Int32],
) -> Unit {
  let inf = 1 << 30
  for i in 0..<(span + 1) {
    best[i] = inf
    advance[i] = 0
    dist_at[i] = 0
    dict_at[i] = -1
    dcopy_at[i] = 0
    run[i] = 0
  }
  best[0] = 0
  let last = span - 1
  for i in 0..<span {
    let base = best[i]
    if base >= inf {
      continue
    }
    let literals = run[i]
    // A literal costs its own code and nothing else: the insert length it is part
    // of is paid for by the command that ends the run, which is the next copy.
    let ctx = literal_context(data, at + i, mode)
    let literal = base + prices.lit[ctx * 256 + data[at + i].to_int()]
    if literal < best[i + 1] {
      best[i + 1] = literal
      advance[i + 1] = 0
      run[i + 1] = literals + 1
    }
    for k in 0..<CANDIDATES {
      let len = blen[i * CANDIDATES + k]
      if len < 4 {
        continue
      }
      // Lengths between the previous candidate's and this one are reachable at
      // this distance and no nearer one.
      let lo = if k == 0 { 4 } else { blen[i * CANDIDATES + k - 1] + 1 }
      let distance = bdist[i * CANDIDATES + k]
      // Every length from `lo` to the longest is a candidate, and on a body with a
      // nine-kilobyte match that is nine thousand relaxations for one step — the
      // walk becomes quadratic in the length of the repeat, which is exactly the
      // shape a compressor is handed most often. The useful lengths are at the two
      // ends: the longest copy available, and the shortest, which leaves the next
      // match the most room. Thirty-two below the top covers a cut made to reach a
      // following match; the first sixty-four cover the short copies a run of
      // literals pays for.
      let top = if len > 32 { len - 31 } else { lo }
      let mut length = lo
      while length <= len {
        if length > lo + 63 && length < top {
          length = top
        }
        let stop = i + length
        let cost = base +
          copy_price(prices, insert_offsets, copy_offsets, literals, length)
        if cost < best[stop] {
          best[stop] = cost
          advance[stop] = length
          dist_at[stop] = distance
          dict_at[stop] = -1
          dcopy_at[stop] = 0
          run[stop] = 0
        }
        length += 1
      }
    }
    // A dictionary word: its address is a distance past the window, so it is
    // never a repeat and always pays a distance code.
    let taken = dtaken[i]
    if taken >= 4 {
      let stop = i + taken
      if stop <= span {
        let word = dwlen[i]
        let address = step_distance(
          { insert: 0, copy: word, taken, distance: 0, dict: daddr[i], },
          at + i,
          reach,
        )
        let (code, extra, _) = distance_codes.code(address)
        let (insert_code, _) = length_code(insert_offsets, literals)
        let (copy_code, _) = length_code(copy_offsets, word)
        let cost = base +
          prices.cmd[command_code(insert_code, copy_code)] +
          prices.dist[code] +
          extra * price_scale +
          (insert_bits[insert_code] + copy_bits[copy_code]) * price_scale
        if cost < best[stop] {
          best[stop] = cost
          advance[stop] = taken
          dist_at[stop] = 0
          dict_at[stop] = daddr[i]
          dcopy_at[stop] = word
          run[stop] = 0
        }
      }
    }
    if i == last {
      // Nothing to do: the loop ends here and the path is read back.
    }
  }
}

///|
/// Read the cheapest path back out of the search, as steps.
///
/// The literals between two copies are one insert run: the path records only the
/// copies, and a gap between them is the run the command carries.
fn rebuild(
  at : Int32,
  span : Int32,
  advance : FixedArray[Int32],
  dist_at : FixedArray[Int32],
  dict_at : FixedArray[Int32],
  dcopy_at : FixedArray[Int32],
) -> Array[Step] {
  let starts : Array[Int32] = []
  let advances : Array[Int32] = []
  let distances : Array[Int32] = []
  let dicts : Array[Int32] = []
  let words : Array[Int32] = []
  let _ = at
  let mut pos = span
  while pos > 0 {
    let taken = advance[pos]
    if taken <= 0 {
      pos -= 1
      continue
    }
    starts.push(pos - taken)
    advances.push(taken)
    distances.push(dist_at[pos])
    dicts.push(dict_at[pos])
    words.push(dcopy_at[pos])
    pos -= taken
  }
  let steps : Array[Step] = []
  let mut emitted = 0
  let mut index = starts.length() - 1
  while index >= 0 {
    let start = starts[index]
    let taken = advances[index]
    let dict = dicts[index]
    steps.push({
      insert: start - emitted,
      copy: if dict >= 0 {
        words[index]
      } else {
        taken
      },
      taken,
      distance: distances[index],
      dict,
    })
    emitted = start + taken
    index -= 1
  }
  let _ = span
  steps
}

///|
/// The parse, the prices and the parse again.
///
/// Three rounds is what this converges in: the first prices from the greedy
/// parse, the second from a parse that has already moved, and the third changes
/// almost nothing. Every round's result is returned rather than only the last,
/// because the last is not always the smallest — the price model cannot see what
/// the code descriptions cost, and a round that spreads its symbols over more of
/// the alphabet looks cheaper to it than it is.
fn optimal_rounds(
  data : BytesView,
  at : Int32,
  span : Int32,
  reach : Int32,
  depth : Int32,
  dictionary : Bool,
  mode : Int32,
  contexts : Bool,
  insert_offsets : FixedArray[Int32],
  copy_offsets : FixedArray[Int32],
  distance_codes : Distances,
  greedy : Array[Step],
  rounds : Int32,
) -> Array[Array[Step]] {
  let blen = FixedArray::make(span * CANDIDATES, 0)
  let bdist = FixedArray::make(span * CANDIDATES, 0)
  let dwlen = FixedArray::make(span, 0)
  let dtaken = FixedArray::make(span, 0)
  let daddr = FixedArray::make(span, 0)
  gather(
    data, at, span, reach, depth, dictionary, blen, bdist, dwlen, dtaken, daddr,
  )
  let best = FixedArray::make(span + 1, 0)
  let advance = FixedArray::make(span + 1, 0)
  let dist_at = FixedArray::make(span + 1, 0)
  let dict_at = FixedArray::make(span + 1, -1)
  let dcopy_at = FixedArray::make(span + 1, 0)
  let run = FixedArray::make(span + 1, 0)
  let out : Array[Array[Step]] = []
  let mut steps = greedy
  for _ in 0..<rounds {
    let prices = Prices::of(
      data, at, span, steps, mode, contexts, insert_offsets, copy_offsets, distance_codes,
      reach,
    )
    choose(
      data, at, span, mode, prices, blen, bdist, dwlen, dtaken, daddr, insert_offsets,
      copy_offsets, distance_codes, reach, best, advance, dist_at, dict_at, dcopy_at,
      run,
    )
    // Cheapened inside the loop, not after it: the ring prices the next round
    // works from are the ones this round's *rewritten* distances fill, and a
    // round that priced the raw distances would find a ring nothing uses and
    // charge fifteen bits for every one of them.
    steps = cheapen(
      data,
      at,
      rebuild(at, span, advance, dist_at, dict_at, dcopy_at),
    )
    out.push(steps)
  }
  out
}
