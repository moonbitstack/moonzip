// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How many literal codes a context-modelled block may spend.
///
/// Each code costs its own description before it saves a single bit, and the map
/// that routes 64 contexts to them costs more the more of them there are. Six is
/// where the two stop paying on the bodies this writer sees; the search below
/// stops earlier whenever a split does not pay.
const MAX_LITERAL_CODES : Int32 = 6

///|
/// Bits the context map spends: its own description, plus one code per context.
///
/// A single code everywhere is one bit — the stream says "no map" and the reader
/// uses that code for all 64 contexts.
fn map_bits(assign : FixedArray[Int32], groups : Int32) -> Int32 {
  if groups <= 1 {
    return 1
  }
  let hist = FixedArray::make(groups, 0)
  for c in 0..<64 {
    hist[assign[c]] += 1
  }
  let tree = Tree::of(hist, 15)
  let mut bits = tree_bits(tree.widths, groups)
  for c in 0..<64 {
    bits += tree.widths[assign[c]]
  }
  bits
}

///|
/// The histogram of one context.
fn context_hist(hist : FixedArray[Int32], context : Int32) -> FixedArray[Int32] {
  let out = FixedArray::make(256, 0)
  for s in 0..<256 {
    out[s] = hist[context * 256 + s]
  }
  out
}

///|
/// How many contexts went to one group.
fn group_size(assign : FixedArray[Int32], group : Int32) -> Int32 {
  let mut n = 0
  for c in 0..<64 {
    if assign[c] == group {
      n += 1
    }
  }
  n
}

///|
/// The histogram of one group of contexts.
fn cluster_hist(
  hist : FixedArray[Int32],
  assign : FixedArray[Int32],
  group : Int32,
) -> FixedArray[Int32] {
  let out = FixedArray::make(256, 0)
  for c in 0..<64 {
    if assign[c] == group {
      let base = c * 256
      for s in 0..<256 {
        out[s] += hist[base + s]
      }
    }
  }
  out
}

///|
/// Bits one context's literals would spend under a code built for another.
///
/// A symbol the code does not cover is charged the longest length the format
/// allows, which is exactly what the reader would pay for it: the map routes a
/// literal to a code, and a code that cannot spell it is a long one, not an error.
fn cross_cost(
  hist : FixedArray[Int32],
  context : Int32,
  widths : FixedArray[Int32],
) -> Int32 {
  let base = context * 256
  let mut bits = 0
  for s in 0..<256 {
    let n = hist[base + s]
    if n > 0 {
      let w = widths[s]
      bits += n * (if w > 0 { w } else { 15 })
    }
  }
  bits
}

///|
/// What a whole assignment spends: every group's code plus the map.
fn cluster_cost(
  hist : FixedArray[Int32],
  assign : FixedArray[Int32],
  groups : Int32,
) -> Int32 {
  let mut total = 0
  for g in 0..<groups {
    let h = cluster_hist(hist, assign, g)
    total += tree_cost(h, Tree::of(h, 15), 256)
  }
  total + map_bits(assign, groups)
}

///|
/// Split one group in two, or say that it does not want to be split.
///
/// The two halves are seeded with the group's largest context and the context
/// that fits that one worst, then refined twice by moving each context to
/// whichever code already spells it cheaper. Two passes are enough: the contexts
/// a text file produces form obvious families, and a third pass moves nothing but
/// the cost of finding that out.
fn bisect(
  hist : FixedArray[Int32],
  assign : FixedArray[Int32],
  group : Int32,
  next : Int32,
) -> (FixedArray[Int32], Tree, Tree) {
  let mut seed = -1
  let mut total = -1
  for c in 0..<64 {
    if assign[c] == group {
      let mut n = 0
      for s in 0..<256 {
        n += hist[c * 256 + s]
      }
      if n > total {
        total = n
        seed = c
      }
    }
  }
  // The context that fits the seed's own code worst becomes the other seed. The
  // code has to be the seed's alone: built from the whole group it already covers
  // every symbol the group uses, and then nothing looks like it fits badly.
  let seed_hist = context_hist(hist, seed)
  let seed_widths = Tree::of(seed_hist, 15).widths
  let mut other = -1
  let mut worst = -1
  for c in 0..<64 {
    if assign[c] == group && c != seed {
      let mut n = 0
      for s in 0..<256 {
        n += hist[c * 256 + s]
      }
      let waste = cross_cost(hist, c, seed_widths) - n
      if waste > worst {
        worst = waste
        other = c
      }
    }
  }
  let side = FixedArray::make(64, 0)
  side[other] = 1
  // Each half starts as its seed alone. Starting the first half as "the group
  // minus the others" would leave the second seed in it, and two codes that cover
  // the same symbols never pull the contexts apart.
  let left = context_hist(hist, seed)
  let right = context_hist(hist, other)
  for _ in 0..<2 {
    let lw = Tree::of(left, 15).widths
    let rw = Tree::of(right, 15).widths
    for s in 0..<256 {
      left[s] = 0
      right[s] = 0
    }
    for c in 0..<64 {
      if assign[c] == group {
        let to = if c == other {
          1
        } else if c == seed {
          0
        } else if cross_cost(hist, c, lw) <= cross_cost(hist, c, rw) {
          0
        } else {
          1
        }
        side[c] = to
        let base = c * 256
        for s in 0..<256 {
          if to == 0 {
            left[s] += hist[base + s]
          } else {
            right[s] += hist[base + s]
          }
        }
      }
    }
  }
  let moved = FixedArray::make(64, 0)
  for c in 0..<64 {
    moved[c] = if side[c] == 1 && assign[c] == group { next } else { assign[c] }
  }
  (moved, Tree::of(left, 15), Tree::of(right, 15))
}

///|
/// Route the 64 literal contexts into as many codes as earn their keep.
///
/// Starts with one code and repeatedly applies the best-paying split it can find,
/// stopping when no split pays or the cap is reached. The result is an assignment
/// per context and the number of codes, which is also the map's alphabet size.
fn group_contexts(hist : FixedArray[Int32]) -> (Int32, FixedArray[Int32]) {
  let mut assign = FixedArray::make(64, 0)
  let mut live = 0
  for c in 0..<64 {
    let mut n = 0
    for s in 0..<256 {
      n += hist[c * 256 + s]
    }
    if n > 0 {
      live += 1
    }
  }
  if live < 4 {
    // Two or three contexts are not worth a map; one code spells them better.
    return (1, assign)
  }
  let mut current = cluster_cost(hist, assign, 1)
  let mut groups = 1
  while groups < MAX_LITERAL_CODES {
    let mut pick = -1
    let mut pick_assign = assign
    let mut pick_cost = current
    for g in 0..<groups {
      // A group of one context has nothing to split; asking would leave `bisect`
      // with no second seed.
      if group_size(assign, g) < 2 {
        continue
      }
      let h = cluster_hist(hist, assign, g)
      let before = tree_cost(h, Tree::of(h, 15), 256) + map_bits(assign, groups)
      let (candidate, ltree, rtree) = bisect(hist, assign, g, groups)
      let after = tree_cost(cluster_hist(hist, candidate, g), ltree, 256) +
        tree_cost(cluster_hist(hist, candidate, groups), rtree, 256) +
        map_bits(candidate, groups + 1)
      let delta = after - before
      if delta < 0 && current + delta < pick_cost {
        pick_cost = current + delta
        pick = g
        pick_assign = candidate
      }
    }
    if pick < 0 {
      break
    }
    assign = pick_assign
    groups += 1
    current = pick_cost
  }
  (groups, assign)
}

///|
/// Which of the four context modes this body wants.
///
/// UTF8 mode is a model of where a byte falls in a UTF-8 character, and it pays
/// on text; LSB6 is the low six bits of the previous byte, which is what binary
/// wants. The test is the share of bytes that are neither printable ASCII nor
/// tab, newline or carriage return.
fn choose_mode(data : BytesView, at : Int32, span : Int32) -> Int32 {
  let n = if span > 65536 { 65536 } else { span }
  let mut odd = 0
  for i in 0..<n {
    let b = data[at + i].to_int()
    if b >= 0x80 || (b < 0x20 && b != 9 && b != 10 && b != 13) {
      odd += 1
    }
  }
  if odd * 10 < n {
    2
  } else {
    0
  }
}
