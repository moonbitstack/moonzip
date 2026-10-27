// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A decoder that can be fed a stream in pieces, which is what LZMA2 needs: the
/// dictionary and the learned probabilities survive across chunks, and only the
/// range coder restarts.
struct Decoder {
  mut model : Model
  mut state : Int32
  reps : FixedArray[Int32]
  out : Array[Byte]
  limit : Int32
}

///|
/// A decoder with the default probabilities and nothing decoded.
pub fn Decoder::new(limit? : Int32) -> Decoder {
  {
    model: Model::new(3, 0, 2),
    state: 0,
    reps: FixedArray::make(4, 0),
    out: [],
    limit: match limit {
      Some(n) => n
      None => -1
    },
  }
}

///|
/// The bytes decoded so far, which for a container is also the dictionary.
pub fn Decoder::output(self : Decoder) -> Bytes {
  Bytes::from_array(self.out)
}

///|
/// How much has been produced — the mark a caller keeps before a chunk.
pub fn Decoder::length(self : Decoder) -> Int32 {
  self.out.length()
}

///|
/// The bytes produced since `mark`, which is how a chunk's output is taken
/// without copying the whole dictionary.
pub fn Decoder::since(self : Decoder, mark : Int32) -> Bytes {
  let made : Array[Byte] = []
  for i in mark..<self.out.length() {
    made.push(self.out[i])
  }
  Bytes::from_array(made)
}

///|
/// Append bytes decoded elsewhere — an LZMA2 chunk that was stored rather than
/// ranged-coded still belongs in the dictionary, or the next chunk's matches
/// would land on the wrong bytes.
pub fn Decoder::append(self : Decoder, data : BytesView) -> Unit {
  for b in data {
    self.out.push(b)
  }
}

///|
/// Forget everything but the model's shape: the start of a stream, or a dictionary
/// reset in LZMA2.
pub fn Decoder::reset(self : Decoder) -> Unit {
  self.state = 0
  for i in 0..<4 {
    self.reps[i] = 0
  }
  for i in 0..<self.model.is_match.length() {
    self.model.is_match[i] = 1024
  }
  for i in 0..<self.model.is_rep.length() {
    self.model.is_rep[i] = 1024
  }
  for i in 0..<self.model.is_rep_g0.length() {
    self.model.is_rep_g0[i] = 1024
    self.model.is_rep_g1[i] = 1024
    self.model.is_rep_g2[i] = 1024
  }
  for i in 0..<self.model.is_rep0_long.length() {
    self.model.is_rep0_long[i] = 1024
  }
  for i in 0..<self.model.pos_slot.length() {
    self.model.pos_slot[i] = 1024
  }
  for i in 0..<self.model.spec_pos.length() {
    self.model.spec_pos[i] = 1024
  }
  for i in 0..<self.model.align.length() {
    self.model.align[i] = 1024
  }
  for i in 0..<self.model.literal.length() {
    self.model.literal[i] = 1024
  }
  for coder in [self.model.len, self.model.rep_len] {
    coder.choice[0] = 1024
    coder.choice2[0] = 1024
    for i in 0..<coder.low.length() {
      coder.low[i] = 1024
      coder.mid[i] = 1024
    }
    for i in 0..<coder.high.length() {
      coder.high[i] = 1024
    }
  }
}

///|
/// Adopt a properties byte: literally `pb * 5 * 9 + lp * 9 + lc`, which is how
/// LZMA packs three small numbers into one.
pub fn Decoder::properties(
  self : Decoder,
  props : Int32,
) -> Unit raise @moonzip.Refused {
  guard props >= 0 && props < 9 * 5 * 5 else {
    raise @moonzip.Header(at=0, what="LZMA properties out of range")
  }
  let lc = props % 9
  let lp = props / 9 % 5
  let pb = props / 45
  self.model = Model::new(lc, lp, pb)
}

///|
/// The properties byte for a set of parameters.
pub fn properties_of(lc : Int32, lp : Int32, pb : Int32) -> Int32 {
  (pb * 5 + lp) * 9 + lc
}

///|
/// Decode until `want` bytes have been produced, or — when `want` is negative —
/// until the end marker. Returns the number produced by this call.
///
/// Everything is measured against `out`, which is both the answer and the
/// dictionary: a back-reference is an index into what has already been produced,
/// so there is nothing else to keep.
pub fn Decoder::feed(
  self : Decoder,
  packed : BytesView,
  want : Int32,
) -> Int32 raise @moonzip.Refused {
  let rc = RangeDecoder::new(packed)
  let from = self.out.length()
  let target = if want >= 0 { from + want } else { -1 }
  while target < 0 || self.out.length() < target {
    if self.limit >= 0 && self.out.length() >= self.limit {
      raise @moonzip.TooBig(limit=self.limit)
    }
    let m = self.model
    let pos = self.out.length()
    let pos_state = pos & m.pos_mask()
    let state = self.state
    if rc.bit(m.is_match, (state << 4) + pos_state) == 0 {
      let prev = if pos > 0 { self.out[pos - 1].to_int() } else { 0 }
      let match_byte = if state >= 7 && pos > self.reps[0] {
        self.out[pos - self.reps[0] - 1].to_int()
      } else {
        0
      }
      self.out.push(decode_literal(rc, m, state, pos, prev, match_byte))
      self.state = if state < 4 {
        0
      } else if state < 10 {
        state - 3
      } else {
        state - 6
      }
      continue
    }
    if rc.bit(m.is_rep, state) == 1 {
      let mut distance = self.reps[0]
      if rc.bit(m.is_rep_g0, state) == 0 {
        if rc.bit(m.is_rep0_long, (state << 4) + pos_state) == 0 {
          // A "short rep": one byte, at the distance of the last match. It is
          // one bit instead of a length and a distance, which is worth having for
          // the repeated line endings every text file is full of.
          guard pos > distance else { raise @moonzip.Distance(at=pos) }
          self.out.push(self.out[pos - distance - 1])
          self.state = if state < 7 { 9 } else { 11 }
          continue
        }
      } else {
        if rc.bit(m.is_rep_g1, state) == 0 {
          distance = self.reps[1]
        } else {
          if rc.bit(m.is_rep_g2, state) == 0 {
            distance = self.reps[2]
          } else {
            distance = self.reps[3]
            self.reps[3] = self.reps[2]
          }
          self.reps[2] = self.reps[1]
        }
        self.reps[1] = self.reps[0]
      }
      self.reps[0] = distance
      let len = decode_length(rc, m.rep_len, pos_state) + 2
      self.state = if state < 7 { 8 } else { 11 }
      self.copy(distance, len)
      continue
    }
    self.reps[3] = self.reps[2]
    self.reps[2] = self.reps[1]
    self.reps[1] = self.reps[0]
    let len = decode_length(rc, m.len, pos_state) + 2
    self.state = if state < 7 { 7 } else { 10 }
    let len_state = if len - 2 < 4 { len - 2 } else { 3 }
    let distance = distance_of(rc, m, len_state)
    if distance == 0xFFFFFFFF {
      // The end marker: a match at a distance no dictionary can have.
      return self.out.length() - from
    }
    self.reps[0] = distance
    self.copy(distance, len)
  }
  self.out.length() - from
}

///|
/// Copy `len` bytes from `distance` back, one at a time so that a run can overlap
/// itself — which is how LZMA encodes a long repetition of one byte as two
/// symbols.
fn Decoder::copy(
  self : Decoder,
  distance : Int32,
  len : Int32,
) -> Unit raise @moonzip.Refused {
  guard distance < self.out.length() else {
    raise @moonzip.Distance(at=self.out.length())
  }
  let start = self.out.length() - distance - 1
  for i in 0..<len {
    let byte = self.out[start + i]
    self.out.push(byte)
  }
}

// ------------------------------------------------------------------ the .lzma form

///|
/// Compress into the `.lzma` "alone" container: thirteen bytes of header, then
/// the range-coded stream.
///
/// The header says the properties (how many context bits the literals use), the
/// dictionary size, and the uncompressed size — which is written, so the stream
/// does not need an end marker. `level` maps to the same presets `xz` uses, and
/// the dictionary is capped at what a decoder can be asked to hold.
pub fn lzma(data : BytesView, level~ : Int32 = 6) -> Bytes {
  guard level >= 0 && level <= 9 else {
    abort("lzma: level \{level} is not between 0 and 9")
  }
  let dict = dictionary_for(level)
  let out : Array[Byte] = []
  out.push(properties_of(3, 0, 2).to_byte())
  for i in 0..<4 {
    out.push(((dict >> (i * 8)) & 0xFF).to_byte())
  }
  let mut left = data.length().to_int64()
  for _ in 0..<8 {
    out.push((left & 0xFFL).to_int().to_byte())
    left = left / 256L
  }
  for b in encode(data, properties_of(3, 0, 2), dict, level~) {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// Read a `.lzma` "alone" container.
///
/// A stream may leave its length unknown and end with a marker instead, which is
/// what every encoder did before sizes could be trusted; both are read here.
pub fn unlzma(data : BytesView, limit? : Int32) -> Bytes raise @moonzip.Refused {
  guard data.length() >= 13 else { raise @moonzip.Truncated(at=data.length()) }
  let props = data[0].to_int()
  let mut size = 0L
  for i in 0..<8 {
    size = size | (data[5 + i].to_uint().to_int64() << (i * 8))
  }
  let decoder = Decoder::new(limit?)
  decoder.properties(props)
  // -1 means "until the end marker"; a stated size is the length to produce.
  let want = if size < 0L || size > 0x7FFFFFFFL { -1 } else { size.to_int() }
  decoder.feed(data[13:], want) |> ignore
  decoder.output()
}

///|
/// The dictionary size a level asks for. It bounds how far back a match may
/// reach, and therefore how much a decoder must hold; 8 MiB at the top is what
/// `xz -9` uses.
pub fn dictionary_for(level : Int32) -> Int32 {
  match level {
    0 => 1 << 16
    1 => 1 << 18
    2 => 1 << 20
    3..<=5 => 1 << 21
    6..<=7 => 1 << 22
    _ => 1 << 23
  }
}
