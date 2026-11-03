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
/// Three things make it worth the walk, and each of them is about something the
/// obvious version of this search gets wrong.
///
/// **The insert run is a state.** "Cheapest way to reach position i" is not the
/// same as "cheapest way to reach i and then copy from i", because a command's
/// insert length is coded jointly with its copy length — an insert of one byte and
/// an insert of twelve sit in different command groups. So the search keeps, for
/// each position, the eight cheapest positions a command could have *ended* at,
/// ordered by how much they cost beyond coding the bytes in between as literals,
/// and tries the copies at this position from each of them. The three cheapest get
/// their match list walked; all eight get the ring.
///
/// **The ring of recent distances is part of the search.** A copy that names one
/// of the last four distances costs two to six bits for the distance instead of
/// five to twenty, and a copy near one of them costs six. Those distances are not
/// in the match list — the chain was built before the parse decided anything — so
/// each of the sixteen short codes is tried at every position, against the ring
/// the cheapest path to the start position would have left behind. The ring is
/// recovered from the path, not carried separately: every command remembers
/// whether its distance was a fresh one, and the chain of those is the ring.
///
/// **Every match the chain holds, not the longest at each distance.** See
/// `gather`.
///
/// Every round is returned rather than only the last, and the caller encodes each
/// of them: a price list cannot see what the code descriptions cost, and the parse
/// that looks cheapest is not always the one that comes out smallest.

///|
/// How many candidate copies are kept at each position: the longest match among
/// the newest candidates, then the next longer one, and so on, each at the nearest
/// distance that reaches it. A longer match farther away and a shorter one close
/// by are the interesting pair, and the slots hold the walk between them. The
/// reference keeps up to 128; the extra ones past thirty-two stopped paying for
/// their walk on every body measured, and each costs a relaxation.
const CANDIDATES : Int32 = 32

///|
/// The largest block the search will take, and the block size the caller splits
/// its input into at these qualities. The tables are about sixty bytes per input
/// byte — nine arrays of positions plus thirty-two candidates each — so a megabyte
/// is sixty megabytes, which is a compressor's budget and not a browser's.
const OPTIMAL_LIMIT : Int32 = 1 << 20

///|
/// How many start positions the search keeps at each position, and how many of
/// them it expands. Eight is the reference's number; five is how many of the eight
/// it tries copies from, because the sixth and later differ from the first by so
/// much that nothing they can reach is cheaper.
const QUEUE : Int32 = 8

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
/// How many of the queue's entries are expanded at all.
const EXPAND : Int32 = 5

///|
/// Past this copy length only the longest copy at a distance is tried. The
/// reference's number: a copy that long is one command either way, and walking the
/// thousand lengths below it changes the output by nothing.
const LONG_COPY : Int32 = 325

///|
/// The sixteen short distance codes, as the ring slot each names and the offset it
/// adds to it. Codes 0-3 are the last four distances; 4-9 are the six neighbours of
/// the newest; 10-15 the six neighbours of the one before it. The ring is newest
/// first, so this is also the order a search should try them in.
let cache_index : FixedArray[Int32] = [
  0, 1, 2, 3, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1,
]

///|
let cache_offset : FixedArray[Int32] = [
  0, 0, 0, 0, -1, 1, -2, 2, -3, 3, -1, 1, -2, 2, -3, 3,
]

///|
/// The copy length table, built once: the search asks for it per relaxation.
let copy_offsets_table : FixedArray[Int32] = offsets_of(copy_bits, 2)

///|
/// The ring every meta-block starts with, newest first.
///
/// The format's four initial distances are 16, 15, 11 and 4, and the newest of
/// them — the one short code 0 names before anything has been copied — is the last
/// of those. Writing the initial state in the other order shifts every short
/// distance by one slot, which a decoder forgives only up to the first copy.
let start_ring : FixedArray[Int32] = [4, 11, 15, 16]

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
/// One round of the walk: the tables, the queue, and the prices they work from.
///
/// The step that reaches a position is stored as the four things a command needs —
/// how many literals it inserts, how many bytes it copies, at what distance, and
/// which dictionary word if it is one — plus the flag that says whether that
/// distance was a fresh one. The flag is what makes the ring recoverable: a command
/// at a repeated distance leaves the ring alone, so the chain of positions with
/// fresh distances is the ring's own history.
priv struct Search {
  span : Int32
  cost : FixedArray[Int32]
  take : FixedArray[Int32]
  dist : FixedArray[Int32]
  insert : FixedArray[Int32]
  dict : FixedArray[Int32]
  word : FixedArray[Int32]
  fresh : FixedArray[Bool]
  shortcut : FixedArray[Int32]
  queue : FixedArray[Int32]
  diff : FixedArray[Int32]
  ring : FixedArray[Int32]
  scratch : FixedArray[Int32]
  /// The command symbol for every insert length up to the block size, and for
  /// every copy length the format codes. Both are lookups an inner loop would
  /// otherwise do as a walk.
  ins_code : FixedArray[Int32]
  cpy_code : FixedArray[Int32]
  mut size : Int32
}

///|
fn Search::new(span : Int32) -> Search {
  let ins_code = FixedArray::make(span + 1, 0)
  let insert_offsets = offsets_of(insert_bits, 0)
  for i in 0..<(span + 1) {
    ins_code[i] = length_code(insert_offsets, i).0
  }
  let cpy_code = FixedArray::make(260, 0)
  for i in 2..<260 {
    cpy_code[i] = length_code(copy_offsets_table, i).0
  }
  {
    span,
    cost: FixedArray::make(span + 1, 0),
    take: FixedArray::make(span + 1, 0),
    dist: FixedArray::make(span + 1, 0),
    insert: FixedArray::make(span + 1, 0),
    dict: FixedArray::make(span + 1, -1),
    word: FixedArray::make(span + 1, 0),
    fresh: FixedArray::make(span + 1, false),
    shortcut: FixedArray::make(span + 1, 0),
    queue: FixedArray::make(QUEUE, 0),
    diff: FixedArray::make(QUEUE, 0),
    ring: FixedArray::make(QUEUE * 4, 0),
    scratch: FixedArray::make(4, 0),
    ins_code,
    cpy_code,
    size: 0,
  }
}

///|
/// Empty the tables for another round.
fn Search::reset(self : Search) -> Unit {
  let inf = 1 << 30
  for i in 0..<(self.span + 1) {
    self.cost[i] = inf
    self.take[i] = 0
    self.dist[i] = 0
    self.insert[i] = 0
    self.dict[i] = -1
    self.word[i] = 0
    self.fresh[i] = false
    self.shortcut[i] = 0
  }
  self.cost[0] = 0
  self.size = 0
}

///|
/// The ring the cheapest path to `pos` would have left behind, newest first.
///
/// Walk back along the positions whose distance was fresh, newest first, and let
/// the four the stream started with fill whatever is left. A path with fewer than
/// four fresh distances reaches the initial ring for the rest — which is what the
/// decoder does too, so the ring the search prices is the ring the reader will
/// have.
fn Search::ring_at(
  self : Search,
  pos : Int32,
  into : FixedArray[Int32],
) -> Unit {
  let mut idx = 0
  let mut p = self.shortcut[pos]
  while idx < 4 && p > 0 {
    into[idx] = self.dist[p]
    idx += 1
    p = self.shortcut[p - self.insert[p] - self.take[p]]
  }
  while idx < 4 {
    into[idx] = start_ring[idx]
    idx += 1
  }
}

///|
/// Note that `pos` is reachable and, if it is worth expanding, put it in the queue.
///
/// `cost - literals` is the number that orders the queue: two starts that cost the
/// same to reach are not equally good, because the one that leaves fewer bytes to
/// code as literals between it and the copy is the cheaper command. `shortcut` is
/// filled in either way, since a start that is not expanded may still be on the
/// path a later position's ring is read from.
fn Search::evaluate(
  self : Search,
  lcost : FixedArray[Int32],
  pos : Int32,
) -> Unit {
  if pos > 0 {
    let prev = pos - self.insert[pos] - self.take[pos]
    self.shortcut[pos] = if self.fresh[pos] {
      pos
    } else if prev >= 0 {
      self.shortcut[prev]
    } else {
      0
    }
  }
  if self.cost[pos] > lcost[pos] {
    // The path is dearer than coding everything up to here as literals, so no
    // command starting here can beat one starting further back.
    return
  }
  self.ring_at(pos, self.scratch)
  self.push(pos, self.cost[pos] - lcost[pos])
}

///|
/// Insert into the queue by "cost beyond literals", keeping the eight cheapest.
fn Search::push(self : Search, pos : Int32, diff : Int32) -> Unit {
  let held = if self.size < QUEUE { self.size } else { QUEUE }
  let mut at = 0
  while at < held && self.diff[at] <= diff {
    at += 1
  }
  if held == QUEUE && at == QUEUE {
    // Dearer than everything already in the queue: it would be the ninth.
    return
  }
  let mut j = if self.size < QUEUE { self.size } else { QUEUE - 1 }
  while j > at {
    self.queue[j] = self.queue[j - 1]
    self.diff[j] = self.diff[j - 1]
    for r in 0..<4 {
      self.ring[j * 4 + r] = self.ring[(j - 1) * 4 + r]
    }
    j -= 1
  }
  self.queue[at] = pos
  self.diff[at] = diff
  for r in 0..<4 {
    self.ring[at * 4 + r] = self.scratch[r]
  }
  if self.size < QUEUE {
    self.size += 1
  }
}

///|
/// Walk the block once, relaxing every command that could reach further.
///
/// The order matters and is the reference's: at each position, first note that the
/// position is reachable, then try the copies from the cheapest starts, ring first
/// because a ring copy needs no distance symbol at all.
fn Search::run(
  self : Search,
  data : BytesView,
  at : Int32,
  prices : Prices,
  lcost : FixedArray[Int32],
  blen : FixedArray[Int32],
  bdist : FixedArray[Int32],
  dwlen : FixedArray[Int32],
  dtaken : FixedArray[Int32],
  daddr : FixedArray[Int32],
  distance_codes : Distances,
  reach : Int32,
) -> Unit {
  let span = self.span
  for i in 0..<span {
    self.evaluate(lcost, i)
    let expand = if self.size < EXPAND { self.size } else { EXPAND }
    let room = span - i
    for k in 0..<expand {
      let start = self.queue[k]
      let ins = self.ins_code[i - start]
      let base = self.diff[k] + lcost[i] + insert_bits[ins] * price_scale
      let mut best = 1
      // The ring, which the chain cannot see: sixteen distances the last few
      // commands used, each of which names itself in two to six bits.
      for j in 0..<16 {
        if best >= room {
          break
        }
        let back = self.ring[k * 4 + cache_index[j]] + cache_offset[j]
        if back <= 0 || back > i {
          continue
        }
        let mut length = 0
        while length < room &&
              data[at + i - back + length] == data[at + i + length] {
          length += 1
        }
        if length <= best {
          continue
        }
        self.relax(
          i,
          start,
          best + 1,
          length,
          back,
          base,
          if j == 0 {
            prices.dist[0]
          } else {
            prices.dist[j]
          },
          prices,
          j,
        )
        best = length
      }
      // The chain's matches. Only the two cheapest starts bother: a start that
      // costs more than the second cheapest differs by enough that the same copy
      // from it cannot win.
      if k >= 2 {
        continue
      }
      for c in 0..<CANDIDATES {
        let length = blen[i * CANDIDATES + c]
        if length < 4 {
          continue
        }
        let lo = if c == 0 { 4 } else { blen[i * CANDIDATES + c - 1] + 1 }
        let distance = bdist[i * CANDIDATES + c]
        let (code, extra, _) = distance_codes.code(distance)
        let dist_cost = prices.dist[code] + extra * price_scale
        // Past a certain length only the longest copy at this distance is worth a
        // command; below it, every length is, because a cut leaves room for the
        // next match.
        if length > LONG_COPY {
          self.relax(
            i, start, length, length, distance, base, dist_cost, prices, -1,
          )
        } else {
          self.relax(
            i, start, lo, length, distance, base, dist_cost, prices, -1,
          )
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
          let cc = self.cpy_code[word]
          let cmd = command_code(ins, cc)
          let cost = base +
            prices.cmd[cmd] +
            prices.dist[code] +
            extra * price_scale +
            copy_bits[cc] * price_scale
          if cost < self.cost[stop] {
            self.cost[stop] = cost
            self.take[stop] = taken
            self.dist[stop] = 0
            self.insert[stop] = i - start
            self.dict[stop] = daddr[i]
            self.word[stop] = word
            self.fresh[stop] = false
          }
        }
      }
    }
  }
}

///|
/// Relax every copy length from `lo` to `hi` at one distance, as one command of
/// `i - start` literals followed by the copy.
///
/// `dist_cost` is what naming the distance costs, or the symbol 0's own price for
/// the newest one. `short` is the ring code this distance names, or -1 when it is a
/// fresh one: a copy at the newest distance needs no distance symbol at all when
/// the lengths allow the command group that means "the distance before", and that
/// group is worth more than a short code because a short code still has to be
/// named in the distance tree.
fn Search::relax(
  self : Search,
  i : Int32,
  start : Int32,
  lo : Int32,
  hi : Int32,
  back : Int32,
  base : Int32,
  dist_cost : Int32,
  prices : Prices,
  short : Int32,
) -> Unit {
  let ins = self.ins_code[i - start]
  let span = self.span
  let mut length = lo
  while length <= hi && i + length <= span {
    // Copies past a few hundred bytes are rare enough that the table stops
    // there; a body of one repeated byte reaches for the walk instead.
    let cc = if length < 260 {
      self.cpy_code[length]
    } else {
      length_code(copy_offsets_table, length).0
    }
    let extras = copy_bits[cc] * price_scale
    let implicit = if short == 0 { implicit_command_code(ins, cc) } else { -1 }
    let cost = if implicit >= 0 {
      base + prices.cmd[implicit] + extras
    } else {
      base + prices.cmd[command_code(ins, cc)] + dist_cost + extras
    }
    let stop = i + length
    if cost < self.cost[stop] {
      self.cost[stop] = cost
      self.take[stop] = length
      self.dist[stop] = back
      self.insert[stop] = i - start
      self.dict[stop] = -1
      self.word[stop] = 0
      self.fresh[stop] = short != 0
    }
    length += 1
  }
}

///|
/// Read the cheapest path back out of the search, as steps.
///
/// The path is a chain of command ends; a position no command reaches is either
/// past the last command — the trailing literals, which the caller's command
/// writer adds on its own — or a position the walk never needed.
fn Search::path(self : Search, at : Int32) -> Array[Step] {
  let mut end = self.span
  while end > 0 && self.take[end] == 0 {
    end -= 1
  }
  let starts : Array[Int32] = []
  let takes : Array[Int32] = []
  let distances : Array[Int32] = []
  let dicts : Array[Int32] = []
  let words : Array[Int32] = []
  let mut pos = end
  while pos > 0 {
    let taken = self.take[pos]
    if taken == 0 {
      break
    }
    starts.push(pos - taken)
    takes.push(taken)
    distances.push(self.dist[pos])
    dicts.push(self.dict[pos])
    words.push(self.word[pos])
    pos = pos - self.insert[pos] - taken
  }
  let steps : Array[Step] = []
  let _ = at
  let mut index = starts.length() - 1
  let mut emitted = 0
  while index >= 0 {
    let start = starts[index]
    let taken = takes[index]
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
  let search = Search::new(span)
  // The cost of coding each byte as a literal, accumulated: what a command's
  // insert run adds is one subtraction, and the queue's ordering needs the
  // difference between two of these.
  let lcost = FixedArray::make(span + 1, 0)
  let out : Array[Array[Step]] = []
  let mut steps = greedy
  for _ in 0..<rounds {
    let prices = Prices::of(
      data, at, span, steps, mode, contexts, insert_offsets, copy_offsets, distance_codes,
      reach,
    )
    let mut acc = 0
    for i in 0..<span {
      lcost[i] = acc
      acc += prices.lit[literal_context(data, at + i, mode) * 256 +
        data[at + i].to_int()]
    }
    lcost[span] = acc
    search.reset()
    search.run(
      data, at, prices, lcost, blen, bdist, dwlen, dtaken, daddr, distance_codes,
      reach,
    )
    steps = cheapen(data, at, search.path(at))
    out.push(steps)
  }
  out
}
