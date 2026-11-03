// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One decision: either a literal (length zero) or a match with its distance.
priv struct Token {
  len : Int32
  /// The distance as the format stores it, which is one less than the number of
  /// bytes back the copy starts.
  distance : Int32
  is_rep : Bool
}

///|
/// An `.lzma` writer that takes the body a piece at a time.
///
/// The format is a single range-coded stream with no block structure, so there is
/// no boundary to reset at: what is held between calls is the dictionary a match
/// may reach into, the hash chains over it, and the learned probabilities. That is
/// a window, not a body — which is what lets a two-gigabyte file be written by a
/// process that never holds two gigabytes.
///
/// The size in the header is left unknown and the stream ends with an end marker,
/// because a writer that has not seen the end of the body cannot promise a length.
///
/// ```moonbit nocheck
/// let w = @lzma.Writer::new(level=6)
/// let mut out : Array[Byte] = []
/// for part in parts {
///   for b in w.push(part[:]) {
///     out.push(b)
///   }
/// }
/// for b in w.finish() {
///   out.push(b)
/// }
/// ```
struct Writer {
  level : Int32
  dict : Int32
  m : Model
  rc : RangeEncoder
  reps : FixedArray[Int32]
  mut state : Int32
  /// The window: every byte a match can still reach, `window[0]` at `base`.
  mut window : Array[Byte]
  mut base : Int32
  /// How much has arrived. The next position to code is `coded`.
  mut size : Int32
  mut coded : Int32
  /// Hash chains over absolute positions: a match is found by walking back
  /// through the positions that share a three-byte prefix.
  head : Array[Int32]
  prev : FixedArray[Int32]
  /// The header, handed out with the first chunk that produces any output.
  mut header : Array[Byte]
  mut closed : Bool
}

///|
pub fn Writer::new(level~ : Int32 = 6, header~ : Bool = true) -> Writer {
  guard level >= 0 && level <= 9 else {
    abort("lzma: level \{level} is not between 0 and 9")
  }
  let dict = dictionary_for(level)
  let out : Array[Byte] = []
  let props = properties_of(3, 0, 2)
  if header {
    out.push(props.to_byte())
    for i in 0..<4 {
      out.push(((dict >> (i * 8)) & 0xFF).to_byte())
    }
    // All ones: the length is unknown, and the end marker says where the stream
    // stops. Every writer that cannot know the size in advance writes this.
    for _ in 0..<8 {
      out.push(b'\xFF')
    }
  }
  {
    level,
    dict,
    m: Model::new(3, 0, 2),
    rc: RangeEncoder::new(),
    reps: FixedArray::make(4, 0),
    state: 0,
    window: [],
    base: 0,
    size: 0,
    coded: 0,
    head: Array::make(1 << 16, -1),
    prev: FixedArray::make(dict, -1),
    header: out,
    closed: false,
  }
}

///|
/// The byte at an absolute position, which is in the window by construction: a
/// match may only reach a dictionary back, and the window holds exactly that.
fn Writer::at(self : Writer, pos : Int32) -> Byte {
  self.window[pos - self.base]
}

///|
/// Drop the bytes a match can no longer reach.
fn Writer::shrink(self : Writer) -> Unit {
  let over = self.coded - self.dict - self.base
  if over <= 0 {
    return
  }
  let rest : Array[Byte] = []
  for i in over..<self.window.length() {
    rest.push(self.window[i])
  }
  self.window = rest
  self.base += over
}

///|
/// The match at `pos`, or a literal when there is none.
///
/// The repeat distance is tried before the chains because it costs a few bits
/// instead of a distance, and a body that repeats a line — or a file that repeats
/// a word — is exactly what that saves.
fn Writer::token(self : Writer, pos : Int32) -> Token {
  let mut best_len = 0
  let mut best_distance = 0
  let mut is_rep = false
  let cap = if self.size - pos < longest_match {
    self.size - pos
  } else {
    longest_match
  }
  let rep = self.reps[0]
  if rep < pos && rep < self.dict {
    let mut len = 0
    while len < cap && self.at(pos - rep - 1 + len) == self.at(pos + len) {
      len += 1
    }
    if len >= 2 {
      best_len = len
      is_rep = true
    }
  }
  // `best_len < cap` rather than the format's limit: a repeat that already covers
  // everything left leaves the chains nothing to improve, and asking for the byte
  // past the end to prove it is a read out of the window.
  if best_len < cap && pos + 3 <= self.size {
    let hash = self.hash(pos)
    let mut candidate = self.head[hash]
    let mut left = depth_of(self.level)
    while candidate >= 0 && left > 0 {
      if candidate < self.base {
        break
      }
      let distance = pos - candidate - 1
      if distance >= self.dict {
        break
      }
      if self.at(candidate + best_len) == self.at(pos + best_len) {
        let mut len = 0
        while len < cap && self.at(candidate + len) == self.at(pos + len) {
          len += 1
        }
        if len > best_len {
          best_len = len
          best_distance = distance
          is_rep = false
          if len >= cap {
            break
          }
        }
      }
      candidate = self.prev[candidate & (self.dict - 1)]
      left -= 1
    }
  }
  if best_len >= 3 || (is_rep && best_len >= 2) {
    { len: best_len, distance: best_distance, is_rep, }
  } else {
    { len: 0, distance: 0, is_rep: false, }
  }
}

///|
fn depth_of(level : Int32) -> Int32 {
  if level <= 3 {
    4
  } else if level <= 6 {
    16
  } else {
    48
  }
}

///|
fn Writer::hash(self : Writer, pos : Int32) -> Int32 {
  let word = (self.at(pos).to_uint() << 16) |
    (self.at(pos + 1).to_uint() << 8) |
    self.at(pos + 2).to_uint()
  ((word * 2654435761U) >> 16).reinterpret_as_int()
}

///|
fn Writer::remember(self : Writer, pos : Int32) -> Unit {
  if pos + 3 <= self.size {
    let hash = self.hash(pos)
    self.prev[pos & (self.dict - 1)] = self.head[hash]
    self.head[hash] = pos
  }
}

///|
/// Code everything up to `limit`, which is the end of the body minus the longest
/// match a later push could still extend.
fn Writer::code(self : Writer, limit : Int32) -> Unit {
  while self.coded < limit {
    let pos = self.coded
    let pos_state = pos & self.m.pos_mask()
    let token = self.token(pos)
    let state = self.state
    if token.len > 0 {
      self.rc.bit(self.m.is_match, (state << 4) + pos_state, 1)
      if token.is_rep {
        self.rc.bit(self.m.is_rep, state, 1)
        self.rc.bit(self.m.is_rep_g0, state, 0)
        self.rc.bit(self.m.is_rep0_long, (state << 4) + pos_state, 1)
        encode_length(self.rc, self.m.rep_len, pos_state, token.len)
        self.state = if state < 7 { 8 } else { 11 }
      } else {
        self.rc.bit(self.m.is_rep, state, 0)
        encode_length(self.rc, self.m.len, pos_state, token.len)
        self.reps[3] = self.reps[2]
        self.reps[2] = self.reps[1]
        self.reps[1] = self.reps[0]
        self.reps[0] = token.distance
        self.state = if state < 7 { 7 } else { 10 }
        let len_state = if token.len - 2 < 4 { token.len - 2 } else { 3 }
        encode_distance(self.rc, self.m, token.distance, len_state)
      }
      // Every position the match covered goes into the chains, or the next match
      // could not start inside this one.
      for step in 0..<token.len {
        self.remember(pos + step)
      }
      self.coded += token.len
      continue
    }
    let prev_byte = if pos > 0 { self.at(pos - 1).to_int() } else { 0 }
    let match_byte = if state >= 7 && pos > self.reps[0] {
      self.at(pos - self.reps[0] - 1).to_int()
    } else {
      0
    }
    self.rc.bit(self.m.is_match, (state << 4) + pos_state, 0)
    encode_literal(
      self.rc,
      self.m,
      state,
      pos,
      prev_byte,
      self.at(pos).to_int(),
      match_byte,
    )
    self.state = if state < 4 {
      0
    } else if state < 10 {
      state - 3
    } else {
      state - 6
    }
    self.remember(pos)
    self.coded += 1
  }
  self.shrink()
}

///|
fn Writer::emit(self : Writer, made : Array[Byte]) -> Bytes {
  if self.header.length() == 0 {
    return Bytes::from_array(made)
  }
  let out : Array[Byte] = []
  for b in self.header {
    out.push(b)
  }
  self.header = []
  for b in made {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
pub fn Writer::push(self : Writer, data : BytesView) -> Bytes {
  if self.closed {
    abort("lzma: the writer is finished")
  }
  for b in data {
    self.window.push(b)
  }
  self.size += data.length()
  // A match may reach `longest_match` bytes forward, so the last that many bytes
  // wait for the next push: coding them now would cut the match short.
  self.code(self.size - longest_match)
  self.emit(self.rc.drain())
}

///|
pub fn Writer::finish(self : Writer) -> Bytes {
  if self.closed {
    return b""
  }
  self.closed = true
  self.code(self.size)
  // An end marker is a match at a distance no dictionary can reach: the length
  // code says "longest", the distance slot says "far", and the decoder stops.
  let pos_state = self.coded & self.m.pos_mask()
  let state = self.state
  self.rc.bit(self.m.is_match, (state << 4) + pos_state, 1)
  self.rc.bit(self.m.is_rep, state, 0)
  encode_length(self.rc, self.m.len, pos_state, longest_match)
  // The marker's distance is the far slot and thirty bits of ones, which is the
  // one distance the ordinary encoder never has to write — and cannot write,
  // because as a signed number it is the one value the slot search cannot place.
  self.rc.tree(self.m.pos_slot, 3 << 6, 6, 63)
  self.rc.direct(0x3FFFFFF, 26)
  self.rc.reverse_tree(self.m.align, 0, 4, 15)
  let made = self.rc.flush()
  let out : Array[Byte] = []
  for b in made {
    out.push(b)
  }
  self.emit(out)
}

///|
/// A `.lzma` reader that is fed a piece at a time.
///
/// There are no blocks to wait for, so the reader stops wherever a token ends and
/// keeps the range coder's three registers — the range, the code and the read
/// position — to carry on from. What it will not do is stop in the middle of a
/// token: the probabilities have been updated by then, and a token cannot be
/// decoded twice. A token can consume at most a few hundred bytes, which is why
/// the reader waits until that much is in hand rather than trying and rewinding.
struct Reader {
  decoder : Decoder
  /// Bytes received and not yet decoded.
  mut pending : Array[Byte]
  /// The range coder's registers, and how far into `pending` it has read.
  mut at : Int32
  mut range : UInt32
  mut code : UInt32
  mut started : Bool
  /// The length the header promised, or -1 for "until the end marker".
  mut want : Int32
  /// The dictionary the header named, which bounds how much output is kept.
  mut dictionary : Int32
  mut done : Bool
  /// Zero at the header, one in the stream, two past the end marker.
  mut stage : Int32
}

///|
/// The most input one token can consume.
///
/// A bit renormalises at most six bytes — a probability never falls below
/// thirty-one of two thousand and forty-eight, so the range never needs more than
/// six shifts to come back — and a token is at most about fifty bits. Five
/// hundred and twelve bytes covers that with room to spare, and holding it back
/// costs a delay of that many bytes, not a copy.
let lookahead : Int32 = 512

///|
pub fn Reader::new(limit? : Int32) -> Reader {
  {
    decoder: Decoder::new(limit?),
    pending: [],
    at: 0,
    range: 0xFFFFFFFFU,
    code: 0U,
    started: false,
    want: -1,
    dictionary: 1 << 23,
    done: false,
    stage: 0,
  }
}

///|
fn Reader::drop(self : Reader, used : Int32) -> Unit {
  if used <= 0 {
    return
  }
  let rest : Array[Byte] = []
  for i in used..<self.pending.length() {
    rest.push(self.pending[i])
  }
  self.pending = rest
  self.at -= used
}

///|
/// Read the thirteen-byte header: the properties, the dictionary, and the length
/// or the all-ones that says there is none.
fn Reader::header(self : Reader) -> Bool raise @moonzip.Refused {
  if self.pending.length() < 13 {
    return false
  }
  let bytes = Bytes::from_array(self.pending)
  let view = bytes[:]
  self.decoder.properties(view[0].to_int())
  let mut dictionary = 0
  for i in 0..<4 {
    dictionary = dictionary | (view[1 + i].to_int() << (i * 8))
  }
  self.dictionary = if dictionary <= 0 { 1 << 16 } else { dictionary }
  let mut size = 0L
  for i in 0..<8 {
    size = size | (view[5 + i].to_uint().to_int64() << (i * 8))
  }
  self.want = if size < 0L || size > 0x7FFFFFFFL { -1 } else { size.to_int() }
  self.drop(13)
  self.stage = 1
  true
}

///|
/// Decode as many tokens as the bytes in hand allow, and hand back what they
/// produced.
fn Reader::decode(
  self : Reader,
  finished : Bool,
) -> Bytes raise @moonzip.Refused {
  let out : Array[Byte] = []
  if !self.started {
    if self.pending.length() < 5 {
      return Bytes::from_array(out)
    }
    if self.pending[0] != b'\x00' {
      raise @moonzip.Header(at=0, what="not a range-coded stream")
    }
    let bytes = Bytes::from_array(self.pending)
    let view = bytes[:]
    let mut code = 0U
    for i in 1..<5 {
      code = (code << 8) | view[i].to_uint()
    }
    self.code = code
    self.range = 0xFFFFFFFFU
    self.at = 5
    self.started = true
  }
  let mark = self.decoder.length()
  while !self.done {
    if self.want >= 0 && self.decoder.length() - self.want >= 0 {
      self.done = true
      break
    }
    let room = self.pending.length() - self.at
    // At the end of the stream there is nothing more coming, and the encoder's
    // five flushed zero bytes are exactly the padding a range decoder expects.
    if !finished && room < lookahead {
      break
    }
    let bytes = Bytes::from_array(self.pending)
    let rc = RangeDecoder::continuing(bytes[:], self.at, self.range, self.code)
    let ended = self.decoder.step(rc)
    self.at = rc.at
    self.range = rc.range
    self.code = rc.code
    if ended {
      self.done = true
    }
  }
  for b in self.decoder.since(mark) {
    out.push(b)
  }
  // Keep one dictionary: that is as far back as the next token can reach.
  self.decoder.trim(self.dictionary)
  self.drop(self.at)
  Bytes::from_array(out)
}

///|
pub fn Reader::push(
  self : Reader,
  data : BytesView,
) -> Bytes raise @moonzip.Refused {
  for b in data {
    self.pending.push(b)
  }
  if self.stage == 0 && !self.header() {
    return b""
  }
  if self.stage == 2 {
    return b""
  }
  self.decode(false)
}

///|
pub fn Reader::finish(self : Reader) -> Bytes raise @moonzip.Refused {
  let tail = self.decode(true)
  if !self.done {
    raise @moonzip.Truncated(at=self.pending.length())
  }
  self.stage = 2
  tail
}
