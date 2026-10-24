// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The range encoder, the mirror of [`RangeDecoder`](range.mbt).
///
/// `low` is sixty-four bits because a carry out of the top is a real thing that
/// has to be held back and then added to every byte already buffered — which is
/// what `cache` and `cache_size` are for. This is the one part of LZMA that looks
/// like a trick; it is also exactly what the reference implementation does.
priv struct RangeEncoder {
  mut low : UInt64
  mut range : UInt32
  mut cache : Byte
  mut cache_size : Int32
  out : Array[Byte]
}

///|
fn RangeEncoder::new() -> RangeEncoder {
  { low: 0UL, range: 0xFFFFFFFFU, cache: 0, cache_size: 1, out: [], }
}

///|
fn RangeEncoder::shift_low(self : RangeEncoder) -> Unit {
  if self.low < 0xFF000000UL || self.low > 0xFFFFFFFFUL {
    let carry = (self.low >> 32).to_int()
    let mut temp = self.cache.to_int()
    let mut left = self.cache_size
    while left > 0 {
      self.out.push((temp + carry).to_byte())
      temp = 0xFF
      left -= 1
    }
    self.cache = ((self.low >> 24) & 0xFFUL).to_int().to_byte()
    self.cache_size = 0
  }
  self.cache_size += 1
  self.low = (self.low & 0xFFFFFFUL) << 8
}

///|
fn RangeEncoder::bit(
  self : RangeEncoder,
  probs : Array[Int32],
  i : Int32,
  bit : Int32,
) -> Unit {
  let bound = (self.range >> 11) * probs[i].reinterpret_as_uint()
  if bit == 0 {
    self.range = bound
    probs[i] = probs[i] + ((2048 - probs[i]) >> 5)
  } else {
    self.low = self.low + bound.to_uint64()
    self.range = self.range - bound
    probs[i] = probs[i] - (probs[i] >> 5)
  }
  while self.range < 0x01000000U {
    self.range = self.range << 8
    self.shift_low()
  }
}

///|
fn RangeEncoder::tree(
  self : RangeEncoder,
  probs : Array[Int32],
  base : Int32,
  bits : Int32,
  symbol : Int32,
) -> Unit {
  let mut m = 1
  for i in 0..<bits {
    let bit = (symbol >> (bits - 1 - i)) & 1
    self.bit(probs, base + m, bit)
    m = (m << 1) | bit
  }
}

///|
fn RangeEncoder::reverse_tree(
  self : RangeEncoder,
  probs : Array[Int32],
  base : Int32,
  bits : Int32,
  symbol : Int32,
) -> Unit {
  let mut m = 1
  for i in 0..<bits {
    let bit = (symbol >> i) & 1
    self.bit(probs, base + m, bit)
    m = (m << 1) | bit
  }
}

///|
fn RangeEncoder::direct(
  self : RangeEncoder,
  value : Int32,
  count : Int32,
) -> Unit {
  for i in 0..<count {
    self.range = self.range >> 1
    if ((value >> (count - 1 - i)) & 1) == 1 {
      self.low = self.low + self.range.to_uint64()
    }
    while self.range < 0x01000000U {
      self.range = self.range << 8
      self.shift_low()
    }
  }
}

///|
fn RangeEncoder::flush(self : RangeEncoder) -> Bytes {
  for _ in 0..<5 {
    self.shift_low()
  }
  Bytes::from_array(self.out)
}

// ------------------------------------------------------------------ the encoder

///|
fn encode_length(
  rc : RangeEncoder,
  coder : Lengths,
  pos : Int32,
  len : Int32,
) -> Unit {
  let value = len - 2
  if value < 8 {
    rc.bit(coder.choice, 0, 0)
    rc.tree(coder.low, pos << 3, 3, value)
  } else if value < 16 {
    rc.bit(coder.choice, 0, 1)
    rc.bit(coder.choice2, 0, 0)
    rc.tree(coder.mid, pos << 3, 3, value - 8)
  } else {
    rc.bit(coder.choice, 0, 1)
    rc.bit(coder.choice2, 0, 1)
    rc.tree(coder.high, 0, 8, value - 16)
  }
}

///|
fn slot_of(distance : Int32) -> Int32 {
  if distance < 4 {
    return distance
  }
  // The bit length, then the bit below the top: two numbers in one slot.
  let mut n = 0
  let mut left = distance
  while left > 1 {
    left = left >> 1
    n += 1
  }
  (n << 1) | ((distance >> (n - 1)) & 1)
}

///|
fn encode_distance(
  rc : RangeEncoder,
  m : Model,
  distance : Int32,
  len_state : Int32,
) -> Unit {
  let slot = slot_of(distance)
  rc.tree(m.pos_slot, len_state << 6, 6, slot)
  if slot < 4 {
    return
  }
  let direct_bits = (slot >> 1) - 1
  let base = (2 | (slot & 1)) << direct_bits
  let rest = distance - base
  if slot < 14 {
    rc.reverse_tree(m.spec_pos, base - slot - 1, direct_bits, rest)
  } else {
    rc.direct(rest >> 4, direct_bits - 4)
    rc.reverse_tree(m.align, 0, 4, rest & 15)
  }
}

///|
/// One literal, through the same tree the decoder walks — including the
/// matched-literal branch, which is taken whenever the last token was a match.
fn encode_literal(
  rc : RangeEncoder,
  m : Model,
  state : Int32,
  pos : Int32,
  prev : Int32,
  byte : Int32,
  match_byte : Int32,
) -> Unit {
  let base = 0x300 *
    (((pos & ((1 << m.lp) - 1)) << m.lc) + (prev >> (8 - m.lc)))
  let mut symbol = 1
  let mut matched = state >= 7
  let mut model_byte = match_byte
  for k in 0..<8 {
    let bit = (byte >> (7 - k)) & 1
    if matched {
      let match_bit = (model_byte >> 7) & 1
      model_byte = model_byte << 1
      rc.bit(m.literal, base + ((1 + match_bit) << 8) + symbol, bit)
      symbol = (symbol << 1) | bit
      if match_bit != bit {
        matched = false
      }
    } else {
      rc.bit(m.literal, base + symbol, bit)
      symbol = (symbol << 1) | bit
    }
  }
}

///|
/// Compress with LZMA, using the given properties and dictionary size.
///
/// The match finder is a hash chain over three bytes, walked greedily: the first
/// match of three or more bytes wins, and the repeat distance is tried before the
/// chain because it costs a handful of bits instead of a distance. That is a
/// long way from an optimal parse, and it is the same order of effort zlib's own
/// level six makes — the point here is a stream that real decoders read, not the
/// last three percent.
pub fn encode(
  data : BytesView,
  props : Int32,
  dict : Int32,
  level~ : Int32 = 6,
) -> Bytes {
  let src = data.to_array()
  let n = src.length()
  let lc = props % 9
  let lp = props / 9 % 5
  let pb = props / 45
  let m = Model::new(lc, lp, pb)
  let rc = RangeEncoder::new()
  let reps = FixedArray::make(4, 0)
  let mut state = 0
  let depth = if level <= 3 { 4 } else if level <= 6 { 16 } else { 48 }
  let head = Array::make(1 << 16, -1)
  let prev = Array::make(if n > 0 { n } else { 1 }, -1)
  let max_match = 273
  let pos_mask = (1 << pb) - 1
  let mut ip = 0
  while ip < n {
    let pos_state = ip & pos_mask
    let mut best_len = 0
    let mut best_dist = 0
    let mut is_rep = false
    // The repeat distance first: one bit says "same distance as last time", and
    // that is much cheaper than a fresh distance even when the match is shorter.
    let rep = reps[0]
    if rep < ip && rep < dict {
      let mut len = 0
      let cap = if n - ip < max_match { n - ip } else { max_match }
      while len < cap && src[ip - rep - 1 + len] == src[ip + len] {
        len += 1
      }
      if len >= 2 {
        best_len = len
        is_rep = true
      }
    }
    if best_len < max_match && ip + 3 <= n {
      let hash = hash3(src, ip)
      let mut candidate = head[hash]
      let mut left = depth
      let cap = if n - ip < max_match { n - ip } else { max_match }
      while candidate >= 0 && left > 0 {
        let distance = ip - candidate - 1
        if distance >= dict {
          break
        }
        let mut len = 0
        while len < cap && src[candidate + len] == src[ip + len] {
          len += 1
        }
        if len > best_len {
          best_len = len
          best_dist = distance
          is_rep = false
          if len >= cap {
            break
          }
        }
        candidate = prev[candidate]
        left -= 1
      }
    }
    if best_len >= 3 || (is_rep && best_len >= 2) {
      rc.bit(m.is_match, (state << 4) + pos_state, 1)
      if is_rep {
        rc.bit(m.is_rep, state, 1)
        rc.bit(m.is_rep_g0, state, 0)
        rc.bit(m.is_rep0_long, (state << 4) + pos_state, 1)
        encode_length(rc, m.rep_len, pos_state, best_len)
        state = if state < 7 { 8 } else { 11 }
      } else {
        rc.bit(m.is_rep, state, 0)
        encode_length(rc, m.len, pos_state, best_len)
        reps[3] = reps[2]
        reps[2] = reps[1]
        reps[1] = reps[0]
        reps[0] = best_dist
        state = if state < 7 { 7 } else { 10 }
        let len_state = if best_len - 2 < 4 { best_len - 2 } else { 3 }
        encode_distance(rc, m, best_dist, len_state)
      }
      // Every position the match covered goes into the chains, or the next
      // match could not start inside this one.
      for step in 0..<best_len {
        let at = ip + step
        if at + 3 <= n {
          let hash = hash3(src, at)
          prev[at] = head[hash]
          head[hash] = at
        }
      }
      ip += best_len
      continue
    }
    let prev_byte = if ip > 0 { src[ip - 1].to_int() } else { 0 }
    let match_byte = if state >= 7 && ip > reps[0] {
      src[ip - reps[0] - 1].to_int()
    } else {
      0
    }
    rc.bit(m.is_match, (state << 4) + pos_state, 0)
    encode_literal(rc, m, state, ip, prev_byte, src[ip].to_int(), match_byte)
    state = if state < 4 {
      0
    } else if state < 10 {
      state - 3
    } else {
      state - 6
    }
    if ip + 3 <= n {
      let hash = hash3(src, ip)
      prev[ip] = head[hash]
      head[hash] = ip
    }
    ip += 1
  }
  rc.flush()
}

///|
fn hash3(src : Array[Byte], at : Int32) -> Int32 {
  let word = (src[at].to_uint() << 16) |
    (src[at + 1].to_uint() << 8) |
    src[at + 2].to_uint()
  ((word * 2654435761U) >> 16).reinterpret_as_int()
}
