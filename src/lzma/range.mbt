// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The range decoder: the arithmetic coder LZMA is built on.
///
/// There is no bit stream here, so there is nothing to align and nothing to
/// mis-align. A probability is an eleven-bit number that says how likely a zero
/// is; each decision splits the range in that proportion, and the side the code
/// falls on is the bit. The probability then moves toward the bit it just
/// produced, by a thirty-second, so the model learns as it goes.
priv struct RangeDecoder {
  data : BytesView
  mut at : Int32
  mut range : UInt32
  mut code : UInt32
}

///|
/// The model starts with range all ones and the first five bytes of the stream as
/// the code — the first of which must be zero, and is skipped.
fn RangeDecoder::new(data : BytesView) -> RangeDecoder raise @moonzip.Refused {
  guard data.length() >= 5 && data[0] == b'\x00' else {
    raise @moonzip.Header(at=0, what="not a range-coded stream")
  }
  let mut code = 0U
  for i in 1..<5 {
    code = (code << 8) | data[i].to_uint()
  }
  { data, at: 5, range: 0xFFFFFFFFU, code, }
}

///|
/// The next byte, or zero past the end. A range decoder is allowed to read a few
/// bytes past what it needs; the encoder flushes five zeros for exactly that.
fn RangeDecoder::next(self : RangeDecoder) -> UInt32 {
  if self.at < self.data.length() {
    let byte = self.data[self.at].to_uint()
    self.at += 1
    byte
  } else {
    self.at += 1
    0U
  }
}

///|
fn RangeDecoder::bit(
  self : RangeDecoder,
  probs : Array[Int32],
  i : Int32,
) -> Int32 {
  let p = probs[i].reinterpret_as_uint()
  let bound = (self.range >> 11) * p
  let bit = if self.code < bound {
    self.range = bound
    probs[i] = probs[i] + ((2048 - probs[i]) >> 5)
    0
  } else {
    self.code -= bound
    self.range -= bound
    probs[i] = probs[i] - (probs[i] >> 5)
    1
  }
  while self.range < 0x01000000U {
    self.range = self.range << 8
    self.code = (self.code << 8) | self.next()
  }
  bit
}

///|
/// A tree of probabilities, most significant bit first: the index walks down the
/// tree, so `probs[m]` is the probability of the next bit at node `m`.
fn RangeDecoder::tree(
  self : RangeDecoder,
  probs : Array[Int32],
  base : Int32,
  bits : Int32,
) -> Int32 {
  let mut m = 1
  for _ in 0..<bits {
    m = (m << 1) | self.bit(probs, base + m)
  }
  m - (1 << bits)
}

///|
/// The same tree, least significant bit first — which is how LZMA stores the low
/// bits of a distance, because that order makes the tree shallower where it is
/// hit most often.
fn RangeDecoder::reverse_tree(
  self : RangeDecoder,
  probs : Array[Int32],
  base : Int32,
  bits : Int32,
) -> Int32 {
  let mut m = 1
  let mut symbol = 0
  for i in 0..<bits {
    let bit = self.bit(probs, base + m)
    m = (m << 1) | bit
    symbol = symbol | (bit << i)
  }
  symbol
}

///|
/// Bits with no model at all: the high half of a long distance, where a model
/// would cost more to learn than the bits cost to send raw.
fn RangeDecoder::direct(self : RangeDecoder, count : Int32) -> Int32 {
  let mut value = 0
  for _ in 0..<count {
    self.range = self.range >> 1
    let bit = if self.code >= self.range {
      self.code -= self.range
      1
    } else {
      0
    }
    while self.range < 0x01000000U {
      self.range = self.range << 8
      self.code = (self.code << 8) | self.next()
    }
    value = (value << 1) | bit
  }
  value
}

// ------------------------------------------------------------------ the model

///|
/// One length coder: a two-level choice, then eight bits in whichever third the
/// choice named. LZMA keeps two of these, one for normal matches and one for
/// repeats, because a repeat's length is distributed differently.
priv struct Lengths {
  choice : Array[Int32]
  choice2 : Array[Int32]
  low : Array[Int32]
  mid : Array[Int32]
  high : Array[Int32]
}

///|
fn Lengths::new() -> Lengths {
  {
    choice: Array::make(2, 1024),
    choice2: Array::make(2, 1024),
    low: Array::make(16 * 8, 1024),
    mid: Array::make(16 * 8, 1024),
    high: Array::make(256, 1024),
  }
}

///|
/// Every probability the codec learns, in one place. Doing this as a flat set of
/// arrays rather than one array with offsets keeps the decoder readable at the
/// cost of a few allocations per stream.
priv struct Model {
  lc : Int32
  lp : Int32
  pb : Int32
  is_match : Array[Int32]
  is_rep : Array[Int32]
  is_rep_g0 : Array[Int32]
  is_rep_g1 : Array[Int32]
  is_rep_g2 : Array[Int32]
  is_rep0_long : Array[Int32]
  pos_slot : Array[Int32]
  spec_pos : Array[Int32]
  align : Array[Int32]
  len : Lengths
  rep_len : Lengths
  literal : Array[Int32]
}

///|
fn Model::new(lc : Int32, lp : Int32, pb : Int32) -> Model {
  {
    lc,
    lp,
    pb,
    is_match: Array::make(12 * 16, 1024),
    is_rep: Array::make(12, 1024),
    is_rep_g0: Array::make(12, 1024),
    is_rep_g1: Array::make(12, 1024),
    is_rep_g2: Array::make(12, 1024),
    is_rep0_long: Array::make(12 * 16, 1024),
    pos_slot: Array::make(4 * 64, 1024),
    spec_pos: Array::make(115, 1024),
    align: Array::make(16, 1024),
    len: Lengths::new(),
    rep_len: Lengths::new(),
    literal: Array::make(0x300 << (lc + lp), 1024),
  }
}

///|
fn Model::pos_mask(self : Model) -> Int32 {
  (1 << self.pb) - 1
}

///|
/// Decode a length bias: zero to seven, eight to fifteen, or sixteen and up. The
/// two the format adds to every match are added by the caller, which is the same
/// split the reference implementation makes.
fn decode_length(rc : RangeDecoder, coder : Lengths, pos : Int32) -> Int32 {
  if rc.bit(coder.choice, 0) == 0 {
    return rc.tree(coder.low, pos << 3, 3)
  }
  if rc.bit(coder.choice2, 0) == 0 {
    return 8 + rc.tree(coder.mid, pos << 3, 3)
  }
  16 + rc.tree(coder.high, 0, 8)
}

///|
/// The distance slot: how many bits the distance needs. Slots zero to three are
/// the distances themselves; above that the slot names a bit count and the top
/// bit.
fn distance_of(rc : RangeDecoder, m : Model, len_state : Int32) -> Int32 {
  let slot = rc.tree(m.pos_slot, len_state << 6, 6)
  if slot < 4 {
    return slot
  }
  let direct_bits = (slot >> 1) - 1
  let base = (2 | (slot & 1)) << direct_bits
  if slot < 14 {
    base + rc.reverse_tree(m.spec_pos, base - slot - 1, direct_bits)
  } else {
    let high = rc.direct(direct_bits - 4) << 4
    high + base + rc.reverse_tree(m.align, 0, 4)
  }
}

///|
/// One literal, with the matched-literal trick: when the previous token was a
/// match the byte it produced is available, and every bit that agrees with it is
/// coded through a different probability — which is the difference between LZMA
/// and an LZ on top of a plain entropy coder.
fn decode_literal(
  rc : RangeDecoder,
  m : Model,
  state : Int32,
  pos : Int32,
  prev : Int32,
  match_byte : Int32,
) -> Byte {
  let base = 0x300 *
    (((pos & ((1 << m.lp) - 1)) << m.lc) + (prev >> (8 - m.lc)))
  if state >= 7 {
    let mut symbol = 1
    let mut byte = match_byte
    while symbol < 0x100 {
      let match_bit = (byte >> 7) & 1
      byte = byte << 1
      let bit = rc.bit(m.literal, base + ((1 + match_bit) << 8) + symbol)
      symbol = (symbol << 1) | bit
      if match_bit != bit {
        while symbol < 0x100 {
          symbol = (symbol << 1) | rc.bit(m.literal, base + symbol)
        }
        break
      }
    }
    (symbol - 0x100).to_byte()
  } else {
    let mut symbol = 1
    while symbol < 0x100 {
      symbol = (symbol << 1) | rc.bit(m.literal, base + symbol)
    }
    (symbol - 0x100).to_byte()
  }
}
