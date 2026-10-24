// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One row of the command table: an insert length, a copy length, and where the
/// distance comes from.
priv struct Cmd {
  insert_bits : Int32
  copy_bits : Int32
  insert : Int32
  copy : Int32
  /// 0 when the command carries its distance implicitly (the last distance
  /// used), -1 when a distance code follows the literals.
  distance : Int32
  /// Which of the four distance contexts the copy length implies.
  context : Int32
}

///|
let insert_bits : FixedArray[Int32] = [
  0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24,
]

///|
let copy_bits : FixedArray[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24,
]

///|
/// `kCellPos` in the reference: each group of 64 command symbols holds a 3x3
/// block of (insert code, copy code) pairs, and this is where each block sits.
/// Index 0 and 1 duplicate index 2 and 3; the duplicates are the spellings that
/// reuse the last distance instead of naming one.
let cell_pos : FixedArray[Int32] = [0, 1, 0, 1, 8, 9, 2, 16, 10, 17, 18]

///|
fn offsets_of(bits : FixedArray[Int32], first : Int32) -> FixedArray[Int32] {
  let out = FixedArray::make(24, 0)
  out[0] = first
  for i in 0..<23 {
    out[i + 1] = out[i] + (1 << bits[i])
  }
  out
}

///|
/// The 704-entry command table, built once.
///
/// Each symbol names an insert code and a copy code three bits at a time, and
/// the group it lives in says whether a distance follows and which context the
/// copy length implies. 704 = 11 groups x 64.
fn command_lut() -> FixedArray[Cmd] {
  let insert = offsets_of(insert_bits, 0)
  let copy = offsets_of(copy_bits, 2)
  let lut = FixedArray::make(704, {
    insert_bits: 0,
    copy_bits: 0,
    insert: 0,
    copy: 2,
    distance: -1,
    context: 0,
  })
  for symbol in 0..<704 {
    let group = symbol >> 6
    let at = cell_pos[group]
    let copy_code = ((at << 3) & 0x18) + (symbol & 0x7)
    let insert_code = (at & 0x18) + ((symbol >> 3) & 0x7)
    let copy_len = copy[copy_code]
    lut[symbol] = {
      insert_bits: insert_bits[insert_code],
      copy_bits: copy_bits[copy_code],
      insert: insert[insert_code],
      copy: copy_len,
      distance: if group >= 2 {
        -1
      } else {
        0
      },
      context: if copy_len > 4 {
        3
      } else {
        copy_len - 2
      },
    }
  }
  lut
}

///|
let cmd_lut : FixedArray[Cmd] = command_lut()

///|
/// The inverse, for the encoder: the 704-symbol spelling of one (insert code,
/// copy code) pair, always in the form that names a distance explicitly.
///
/// Nine groups, not eleven: the two that reuse the last distance are the same
/// pairs under a different distance rule, and a writer that always writes its
/// distances has no use for them.
fn command_code(insert_code : Int32, copy_code : Int32) -> Int32 {
  let cell = (insert_code >> 3 << 3) | (copy_code >> 3)
  let group = if cell == 0 {
    2
  } else if cell == 1 {
    3
  } else if cell == 8 {
    4
  } else if cell == 9 {
    5
  } else if cell == 2 {
    6
  } else if cell == 16 {
    7
  } else if cell == 10 {
    8
  } else if cell == 17 {
    9
  } else {
    10
  }
  (group << 6) | ((insert_code & 7) << 3) | (copy_code & 7)
}

///|
/// The code and the extra bits for a length in `table`, the smallest code that
/// covers it. Every length has exactly one such code, so this is a lookup, not a
/// search.
fn length_code(table : FixedArray[Int32], value : Int32) -> (Int32, Int32) {
  let mut code = 23
  while code > 0 && table[code] > value {
    code -= 1
  }
  (code, value - table[code])
}

///|
/// Block lengths are coded like a prefix code over 26 ranges whose extra bits
/// grow from two to twenty-four.
let block_len_offset : FixedArray[Int32] = [
  1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369,
  497, 753, 1265, 2289, 4337, 8433, 16625,
]

///|
let block_len_bits : FixedArray[Int32] = [
  2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13,
  24,
]

///|
/// The distance codes for one (NPOSTFIX, NDIRECT) pair.
///
/// Codes 0-15 are the short codes — "the last distance", "the one before", and
/// four near neighbours — and are handled by the ring buffer. From 16 on the code
/// names a power-of-two bucket, each bucket split into `1 << npostfix` lanes, and
/// the extra bits pick one distance inside it.
priv struct Distances {
  extra : FixedArray[Int32]
  offset : FixedArray[Int32]
  npostfix : Int32
}

///|
fn distances(npostfix : Int32, ndirect : Int32, size : Int32) -> Distances {
  let extra = FixedArray::make(size, 0)
  let offset = FixedArray::make(size, 0)
  let lane = 1 << npostfix
  let mut i = 16
  for j in 0..<ndirect {
    if i < size {
      offset[i] = j + 1
      i += 1
    }
  }
  let mut bits = 1
  let mut half = 0
  while i < size {
    let base = ndirect + ((((2 + half) << bits) - 4) << npostfix) + 1
    for j in 0..<lane {
      if i < size {
        extra[i] = bits
        offset[i] = base + j
        i += 1
      }
    }
    bits += half
    half = half ^ 1
  }
  { extra, offset, npostfix, }
}

///|
/// The inverse: the code and extra bits that name `distance`.
///
/// Only NPOSTFIX = 0 is inverted here, and that is the only shape the writer
/// emits: without postfix lanes the buckets are contiguous, so the answer is the
/// last code whose range starts at or below the distance. With lanes the ranges
/// interleave and this walk would be wrong, which is why `encode` never asks.
fn Distances::code(self : Distances, distance : Int32) -> (Int32, Int32, Int32) {
  let mut i = self.offset.length() - 1
  while i > 16 && self.offset[i] > distance {
    i -= 1
  }
  (i, self.extra[i], distance - self.offset[i])
}
