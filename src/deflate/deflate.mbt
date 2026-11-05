// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Which block types the writer may emit.
///
/// A DEFLATE stream is a run of blocks, and a block may be stored verbatim,
/// coded with the fixed Huffman table, or coded with a table of its own. All
/// three are ordinary DEFLATE; they differ only in size.
#derive(Eq, Debug)
pub(all) enum Blocks {
  /// Let the writer choose per block: it writes each candidate, measures, and
  /// keeps the smallest. This is what zlib does, and on the short bodies a
  /// response compressor sees the measurement usually lands on fixed — a
  /// dynamic block must carry its own code tables, which costs more than it
  /// saves on a few hundred bytes.
  Auto
  /// Fixed Huffman codes only. Exactly what this library wrote before 0.4.0,
  /// for a caller whose output bytes are pinned.
  Fixed
  /// Dynamic Huffman codes only: the writer must carry its own code tables.
  /// The largest output on text, and the reason to have it on at all.
  Dynamic
  /// No compression at all: the input verbatim in stored blocks. This is what
  /// `level = 0` means, and asking for it by name is the way to say it without
  /// going through a level.
  Stored
}

///|
pub extend Blocks with Eq::{equal, not_equal}

///|
pub extend Blocks with Debug::{to_repr}

///|
/// Compress into a DEFLATE stream, one block over the whole input.
///
/// LZ77 finds back-references with a hash chain over the window, capped so the
/// search stays linear in the input. `blocks` decides how the result is coded.
///
/// `level` runs 0 to 9 and means what it means in the format's reference: 0 stores the
/// input without compressing it, 9 searches hardest, and 6 is the default every
/// mainstream encoder uses. It sets how far back the match finder looks, with the
/// same numbers the reference tables give it.
///
/// `window` is how far a back-reference may reach — 32 KiB is the most DEFLATE
/// allows and the only value a reader can be assumed to handle. `chain` sets
/// the search depth directly for a caller who would rather not go through a
/// level.
///
/// `level=0` writes stored blocks, which is what "no compression" means
/// everywhere; `blocks` then has nothing to choose between.
pub fn deflate(
  data : BytesView,
  level~ : Int32 = 6,
  window~ : Int32 = 32768,
  chain? : Int32,
  blocks~ : Blocks = Auto,
) -> Bytes {
  guard level >= 0 && level <= 9 else {
    abort("deflate: level \{level} is not between 0 and 9")
  }
  guard window >= 256 && window <= 32768 else {
    abort("deflate: a \{window}-byte window is outside what DEFLATE allows")
  }
  if level == 0 || blocks is Stored {
    return stored_blocks(data)
  }
  let buf = data.to_array()
  let (good, nice, standard) = settings_for(level)
  let finder = {
    depth: match chain {
      Some(given) => given
      None => standard
    },
    nice,
    good,
  }
  let bw = BitWriter::new()
  emit_block(bw, buf, data, 0, buf.length(), window, finder, blocks, true)
  bw.finish()
}

///|
/// Decompress a raw DEFLATE stream.
///
/// All three block types: stored, fixed Huffman, and the dynamic Huffman blocks
/// that carry their own code tables — which is what zlib, gzip and every browser
/// actually emit, so a reader without them reads almost nothing.
///
/// `limit` bounds the output. A compressed stream says nothing about how much it
/// expands to, and a small one can expand to more memory than the machine has;
/// a reader handling input from elsewhere should say how much it is prepared to
/// hold. Unbounded by default, which is what every library does.
pub fn inflate(
  data : BytesView,
  limit? : Int32,
) -> Bytes raise @moonzip.Refused {
  let reader = Reader::new(limit?)
  // The reader hands bytes back as it goes; the one-shot caller wants all of
  // them at once. One push carries the whole stream, so the second piece is
  // almost always empty — and copying the first one into a fresh array to add
  // nothing to it is a megabyte and a half of memcpy per call for no reason.
  let first = reader.push(data)
  let more = reader.finish()
  if more.length() == 0 {
    first
  } else {
    let out : Array[Byte] = []
    for part in [first, more] {
      let at = out.length()
      out.resize(at + part.length(), b'\x00')
      for i in 0..<part.length() {
        out[at + i] = part[i]
      }
    }
    Bytes::from_array(out)
  }
}

// ------------------------------------------------------------------ the tables

///|
/// The base length for each length symbol 257–285 (RFC 1951 §3.2.5).
let length_base : FixedArray[Int32] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
  99, 115, 131, 163, 195, 227, 258,
]

///|
let length_extra : FixedArray[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5,
  5, 0,
]

///|
/// The base distance for each distance symbol 0–29.
let dist_base : FixedArray[Int32] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]

///|
let dist_extra : FixedArray[Int32] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
  12, 12, 13, 13,
]

///|
let min_match : Int32 = 3

///|
let max_match : Int32 = 258

///|
/// How hard the match finder looks at each level: the search depth, the length
/// past which a match is good enough to stop looking, and the length past which
/// the search is cut to a quarter.
///
/// The numbers are zlib's own `configuration_table`, so that a level here means
/// what it means there. The two length bounds are most of what makes a level
/// fast: on a body where the same phrase recurs, every candidate reaches the
/// maximum copy length, and a finder that keeps walking a hundred and twenty-eight
/// of them to confirm it is a finder that spends its time proving it already had
/// the answer.

///|
/// What the match finder carries between positions: how deep to walk, when to
/// stop because the match is long enough, and when to walk a quarter as deep
/// because it is already good.
priv struct Finder {
  depth : Int32
  nice : Int32
  good : Int32
}

///|
/// The (good, nice, chain) triple zlib's level table gives: the length at which
/// the search starts cutting its depth, the length at which it stops, and the
/// depth.
fn settings_for(level : Int32) -> (Int32, Int32, Int32) {
  match level {
    0 => (0, 0, 0)
    1 => (0, 258, 4)
    2 => (0, 258, 8)
    3 => (0, 258, 32)
    4 => (0, 258, 16)
    5 => (0, 258, 32)
    6 => (0, 258, 128)
    7 => (0, 258, 256)
    8 => (0, 258, 1024)
    _ => (0, 258, 4096)
  }
}

///|
/// The length symbol a match length takes, for every length the format codes.
let length_index_of : FixedArray[Int32] = {
  let out = FixedArray::make(259, 28)
  let mut i = 0
  for len in 3..<259 {
    while i + 1 < 29 && length_base[i + 1] <= len {
      i += 1
    }
    out[len] = i
  }
  out
}

///|
/// The distance symbol a distance takes, for every distance a 32 KiB window
/// reaches. A table rather than a walk because this is asked twice per copy.
let distance_index_of : FixedArray[Int32] = {
  let out = FixedArray::make(32769, 29)
  let mut i = 0
  for dist in 1..<32769 {
    while i + 1 < 30 && dist_base[i + 1] <= dist {
      i += 1
    }
    out[dist] = i
  }
  out
}

///|
/// The base and the extra-bit count of each length symbol, in one word: the
/// reader asks both for every match it decodes, and two tables is two loads
/// through two pointers where one would do.
let length_info : FixedArray[Int32] = {
  let out = FixedArray::make(29, 0)
  for i in 0..<29 {
    out[i] = (length_base[i] << 5) | length_extra[i]
  }
  out
}

///|
/// The same for each distance symbol: base in the high bits, extra-bit count in
/// the low five, which holds every base the format defines.
let distance_info : FixedArray[Int32] = {
  let out = FixedArray::make(30, 0)
  for i in 0..<30 {
    out[i] = (dist_base[i] << 5) | dist_extra[i]
  }
  out
}

///|
/// The length symbol a match length takes.
fn length_index(len : Int32) -> Int32 {
  if len < 3 {
    0
  } else if len < 259 {
    length_index_of[len]
  } else {
    28
  }
}

///|
/// The distance symbol a distance takes.
fn distance_index(dist : Int32) -> Int32 {
  if dist < 1 {
    0
  } else if dist < 32769 {
    distance_index_of[dist]
  } else {
    29
  }
}

///|
/// Three bytes folded into a chain bucket.
fn hash3(buf : Array[Byte], i : Int32) -> Int32 {
  ((buf[i].to_int() << 10) ^ (buf[i + 1].to_int() << 5) ^ buf[i + 2].to_int()) &
  0x7FFF
}

// ------------------------------------------------------------------ the writer

///|
/// Compress into a DEFLATE stream a piece at a time.
///
/// The point of the streaming writer is that a body need not be held to be
/// compressed: `push` takes whatever has arrived and hands back whatever is
/// ready, and the only thing kept between calls is the last 32 KiB — the
/// window, which is as far back as a back-reference may reach. A block is
/// emitted every 32 KiB of input, and matches may reach back across block
/// boundaries into the retained window, exactly as they would in a stream
/// written in one piece.
///
/// The stream is not finished until `finish` is called: that is what writes the
/// last block, and a caller who stops pushing without it has an unterminated
/// stream.
struct Writer {
  bw : BitWriter
  /// The retained window followed by the input not yet emitted.
  mut buf : Array[Byte]
  /// Everything before this offset is already in the output.
  mut from : Int32
  window : Int32
  finder : Finder
  blocks : Blocks
  mut closed : Bool
}

///|
pub fn Writer::new(
  level~ : Int32 = 6,
  window~ : Int32 = 32768,
  chain? : Int32,
  blocks~ : Blocks = Auto,
) -> Writer {
  guard level >= 0 && level <= 9 else {
    abort("deflate: level \{level} is not between 0 and 9")
  }
  guard window >= 256 && window <= 32768 else {
    abort("deflate: a \{window}-byte window is outside what DEFLATE allows")
  }
  let (good, nice, standard) = settings_for(level)
  let finder = {
    depth: match chain {
      Some(given) => given
      None => standard
    },
    nice,
    good,
  }
  {
    bw: BitWriter::new(),
    buf: [],
    from: 0,
    window,
    finder,
    // A level of zero is "do not compress", and the block choice has nothing
    // to decide in that case.
    blocks: if level == 0 {
      Stored
    } else {
      blocks
    },
    closed: false,
  }
}

///|
/// Feed a chunk, take the compressed bytes it produced.
pub fn Writer::push(self : Writer, data : BytesView) -> Bytes {
  guard !self.closed else { abort("deflate: the writer is finished") }
  for b in data {
    self.buf.push(b)
  }
  while self.buf.length() - self.from >= chunk {
    emit_block(
      self.bw,
      self.buf,
      Bytes::from_array(self.buf[:]),
      self.from,
      self.from + chunk,
      self.window,
      self.finder,
      self.blocks,
      false,
    )
    self.from += chunk
    self.retain()
  }
  self.bw.take()
}

///|
/// Keep the window and drop the history before it.
fn Writer::retain(self : Writer) -> Unit {
  let drop_to = self.from - self.window
  if drop_to > 0 {
    let kept : Array[Byte] = []
    for i in drop_to..<self.buf.length() {
      kept.push(self.buf[i])
    }
    self.buf = kept
    self.from = self.window
  }
}

///|
/// Finish the stream: the last block, and the last bytes of it. Nothing may be
/// pushed afterwards.
pub fn Writer::finish(self : Writer) -> Bytes {
  if !self.closed {
    self.closed = true
    emit_block(
      self.bw,
      self.buf,
      Bytes::from_array(self.buf[:]),
      self.from,
      self.buf.length(),
      self.window,
      self.finder,
      self.blocks,
      true,
    )
  }
  self.bw.finish()
}

///|
/// How much input a streaming writer holds before emitting a block.
let chunk : Int32 = 32768

///|
/// How far a back-reference may reach, and so how much output a streaming
/// reader keeps after handing it over (RFC 1951 §3.2.5).
let window : Int32 = 32768

// ------------------------------------------------------------ the block writer

///|
/// Emit one block covering `buf[from:]`, in whichever form `blocks` allows.
fn emit_block(
  bw : BitWriter,
  buf : Array[Byte],
  words : BytesView,
  from : Int32,
  to : Int32,
  window : Int32,
  finder : Finder,
  blocks : Blocks,
  last : Bool,
) -> Unit {
  let (lens, dists) = parse(buf, words, from, to, window, finder)
  match blocks {
    Fixed => write_fixed(bw, lens, dists, last)
    Dynamic => write_dynamic(bw, lens, dists, last)
    Stored => write_stored(bw, buf, from, to, last)
    Auto => {
      // The dynamic candidate is written out to be measured, and written again
      // only if it won — a block's bits are the same wherever it starts, but
      // its bytes are not, so the winner has to be emitted in place.
      let probe = BitWriter::new()
      write_dynamic(probe, lens, dists, last)
      let fixed = fixed_cost(lens, dists)
      let stored = stored_cost(to - from)
      if probe.count < fixed && probe.count < stored {
        bw.append(probe)
      } else if fixed <= stored {
        write_fixed(bw, lens, dists, last)
      } else {
        write_stored(bw, buf, from, to, last)
      }
    }
  }
}

///|
/// The LZ77 parse: one entry per token, a literal as a zero length with its
/// byte in the distance slot, a match as its length and distance. The tokens
/// are kept rather than emitted on the fly because the writer measures a
/// candidate block before it commits to one, and measuring means walking the
/// tokens twice.
fn parse(
  buf : Array[Byte],
  words : BytesView,
  from : Int32,
  to : Int32,
  window : Int32,
  finder : Finder,
) -> (Array[Int32], Array[Int32]) {
  let n = to
  let lens : Array[Int32] = []
  let dists : Array[Int32] = []
  let head = Array::make(1 << 15, -1)
  let prev = Array::make(if buf.length() > 0 { buf.length() } else { 1 }, -1)
  // The retained window goes into the chains first, or the first block of a
  // stream could not match against anything before it.
  let mut i = 0
  while i < from {
    if i + min_match <= n {
      let h = hash3(buf, i)
      prev.unsafe_set(i, head.unsafe_get(h))
      head.unsafe_set(h, i)
    }
    i += 1
  }
  i = from
  while i < n {
    let mut best_len = 0
    let mut best_dist = 0
    if i + min_match <= n {
      let cap = if n - i < max_match { n - i } else { max_match }
      let h = hash3(buf, i)
      // The head of the chain before this position joins it, so that the search
      // never offers the byte string itself as a match at distance zero.
      let mut j = head.unsafe_get(h)
      prev.unsafe_set(i, j)
      head.unsafe_set(h, i)
      let mut left = finder.depth
      let mut cut = false
      while j >= 0 && left > 0 {
        let dist = i - j
        if dist > window {
          break
        }
        // The byte just past the best match so far decides whether this
        // candidate can beat it, before a single byte is compared.
        if buf.unsafe_get(j + best_len) == buf.unsafe_get(i + best_len) {
          // Four bytes at a time: a load of the same word from both sides
          // answers four byte comparisons at once, and a mismatch is settled by
          // the byte loop below, which never runs past the first unequal byte.
          let mut len = 0
          while len + 4 <= cap &&
                words.unsafe_read_uint32_le(j + len) ==
                words.unsafe_read_uint32_le(i + len) {
            len += 4
          }
          while len < cap && buf.unsafe_get(j + len) == buf.unsafe_get(i + len) {
            len += 1
          }
          if len > best_len {
            best_len = len
            best_dist = dist
            if len >= cap || len >= finder.nice {
              break
            }
            // A match this long is already good; the rest of the chain is
            // unlikely to beat it by enough to pay for the walk.
            if !cut && len >= finder.good && finder.good > 0 {
              left = left >> 2
              cut = true
            }
          }
        }
        j = prev.unsafe_get(j)
        left -= 1
      }
    }
    let taken = if best_len >= min_match {
      lens.push(best_len)
      dists.push(best_dist)
      best_len
    } else {
      lens.push(0)
      dists.push(buf[i].to_int())
      1
    }
    // Every position inside a match still goes into the chain, or the next
    // match cannot start in the middle of this one. The position this step
    // started at is already in.
    let mut k = 1
    while k < taken {
      let at = i + k
      if at + min_match <= n {
        let h = hash3(buf, at)
        prev.unsafe_set(at, head.unsafe_get(h))
        head.unsafe_set(h, at)
      }
      k += 1
    }
    i += taken
  }
  (lens, dists)
}

///|
/// Level 0: the input verbatim in stored blocks (RFC 1951 §3.2.4). A stored
/// block carries at most 65535 bytes, so a longer input takes several.
fn stored_blocks(data : BytesView) -> Bytes {
  let bw = BitWriter::new()
  let buf = data.to_array()
  write_stored(bw, buf, 0, buf.length(), true)
  bw.finish()
}

///|
/// What a stored block costs: three bits of header, padding to the byte
/// boundary, sixteen bits of length and sixteen of its complement, then the
/// bytes themselves — per 65535-byte block.
fn stored_cost(n : Int32) -> Int32 {
  let blocks = if n == 0 { 1 } else { (n + 65534) / 65535 }
  blocks * (5 + 32) + n * 8
}

///|
/// What the fixed table costs over these tokens, the end-of-block code
/// included.
fn fixed_cost(lens : Array[Int32], dists : Array[Int32]) -> Int32 {
  let mut bits = 7
  for i in 0..<lens.length() {
    if lens[i] == 0 {
      let (_, width) = fixed_code(dists[i])
      bits += width
    } else {
      let li = length_index(lens[i])
      let (_, width) = fixed_code(257 + li)
      bits += width + length_extra[li]
      let dc = distance_index(dists[i])
      bits += 5 + dist_extra[dc]
    }
  }
  bits
}

///|
/// The stored form, which no code table touches.
fn write_stored(
  bw : BitWriter,
  buf : Array[Byte],
  from : Int32,
  to : Int32,
  last : Bool,
) -> Unit {
  let n = to
  let mut at = from
  let mut first = true
  while at < n || first {
    let len = if n - at > 65535 { 65535 } else { n - at }
    first = false
    let last = last && at + len >= n
    bw.bits(if last { 1 } else { 0 }, 1)
    bw.bits(0, 2)
    while bw.held != 0 {
      bw.bits(0, 1)
    }
    bw.bits(len, 16)
    bw.bits(len ^ 0xFFFF, 16)
    bw.raw_range(buf, at, at + len)
    at += len
  }
}

///|
/// The fixed form: the table every reader has, so the block carries no code
/// tables of its own.
fn write_fixed(
  bw : BitWriter,
  lens : Array[Int32],
  dists : Array[Int32],
  last : Bool,
) -> Unit {
  bw.bits(if last { 1 } else { 0 }, 1)
  bw.bits(1, 2)
  for i in 0..<lens.length() {
    if lens[i] == 0 {
      emit(bw, dists[i])
    } else {
      emit_match(bw, lens[i], dists[i])
    }
  }
  emit(bw, 256)
}

///|
/// The dynamic form: the block carries the widths of both alphabets, run-length
/// coded over a third alphabet of nineteen symbols, and the data under codes
/// built from those widths (RFC 1951 §3.2.7).
fn write_dynamic(
  bw : BitWriter,
  lens : Array[Int32],
  dists : Array[Int32],
  last : Bool,
) -> Unit {
  let lit_freq = Array::make(286, 0)
  let dist_freq = Array::make(30, 0)
  lit_freq[256] = 1
  for i in 0..<lens.length() {
    if lens[i] == 0 {
      lit_freq[dists[i]] += 1
    } else {
      lit_freq[257 + length_index(lens[i])] += 1
      dist_freq[distance_index(dists[i])] += 1
    }
  }
  // A distance alphabet with nothing in it still needs one code, so that the
  // table a decoder builds from these widths is well formed.
  let mut any_distance = false
  for i in 0..<30 {
    if dist_freq[i] > 0 {
      any_distance = true
    }
  }
  if !any_distance {
    dist_freq[0] = 1
  }
  let lit_len = code_lengths(lit_freq, 15)
  let dist_len = code_lengths(dist_freq, 15)
  let lit_code = canonical(lit_len, 286, 15)
  let dist_code = canonical(dist_len, 30, 15)
  let nlit = reach(lit_len, 286, 257)
  let ndist = reach(dist_len, 30, 1)
  // The widths themselves, as the code-length alphabet sees them.
  let cl_syms : Array[Int32] = []
  let cl_extra : Array[Int32] = []
  let cl_vals : Array[Int32] = []
  let mut at = 0
  while at < nlit + ndist {
    let value = if at < nlit { lit_len[at] } else { dist_len[at - nlit] }
    let mut run = 1
    while at + run < nlit + ndist &&
          (if at + run < nlit {
            lit_len[at + run]
          } else {
            dist_len[at + run - nlit]
          }) ==
          value {
      run += 1
    }
    let whole = run
    if value == 0 {
      // A run of zeros: symbol 17 repeats three to ten, symbol 18 eleven to
      // 138. A remainder of one or two goes out as itself.
      while run >= 3 {
        if run >= 11 {
          let take = if run > 138 { 138 } else { run }
          cl_syms.push(18)
          cl_extra.push(7)
          cl_vals.push(take - 11)
          run -= take
        } else {
          cl_syms.push(17)
          cl_extra.push(3)
          cl_vals.push(run - 3)
          run = 0
        }
      }
      for _ in 0..<run {
        cl_syms.push(0)
        cl_extra.push(0)
        cl_vals.push(0)
      }
    } else {
      // Any other run: the value once, then symbol 16 for repeats of three to
      // six of whatever came before.
      cl_syms.push(value)
      cl_extra.push(0)
      cl_vals.push(0)
      run -= 1
      while run >= 3 {
        let take = if run > 6 { 6 } else { run }
        cl_syms.push(16)
        cl_extra.push(2)
        cl_vals.push(take - 3)
        run -= take
      }
      for _ in 0..<run {
        cl_syms.push(value)
        cl_extra.push(0)
        cl_vals.push(0)
      }
    }
    at += whole
  }
  let cl_freq = Array::make(19, 0)
  for s in cl_syms {
    cl_freq[s] += 1
  }
  let cl_len = code_lengths(cl_freq, 7)
  let cl_code = canonical(cl_len, 19, 7)
  let mut ncode = 4
  for p in 0..<19 {
    if cl_len[length_order[p]] != 0 {
      ncode = p + 1
    }
  }
  if ncode < 4 {
    ncode = 4
  }
  bw.bits(if last { 1 } else { 0 }, 1)
  bw.bits(2, 2)
  bw.bits(nlit - 257, 5)
  bw.bits(ndist - 1, 5)
  bw.bits(ncode - 4, 4)
  for p in 0..<ncode {
    bw.bits(cl_len[length_order[p]], 3)
  }
  let lit_pack = pack_codes(lit_code, lit_len, 286)
  let dist_pack = pack_codes(dist_code, dist_len, 30)
  // The code lengths of this block's own tables: a few dozen symbols, written
  // through the slow spelling because nothing here is on a hot path.
  for i in 0..<cl_syms.length() {
    let s = cl_syms[i]
    bw.huff(cl_code[s], cl_len[s])
    if cl_extra[i] > 0 {
      bw.bits(cl_vals[i], cl_extra[i])
    }
  }
  for i in 0..<lens.length() {
    let len = lens[i]
    let distance = dists[i]
    if len == 0 {
      let entry = lit_pack[distance]
      bw.bits(entry >> 5, entry & 31)
    } else {
      let li = length_index(len)
      let entry = lit_pack[257 + li]
      bw.bits(entry >> 5, entry & 31)
      let le = length_extra[li]
      if le > 0 {
        bw.bits(len - length_base[li], le)
      }
      let dc = distance_index(distance)
      let packed = dist_pack[dc]
      bw.bits(packed >> 5, packed & 31)
      let de = dist_extra[dc]
      if de > 0 {
        bw.bits(distance - dist_base[dc], de)
      }
    }
  }
  let eob = lit_pack[256]
  bw.bits(eob >> 5, eob & 31)
}

///|
/// The fixed table with each code already reversed for the stream's bit order,
/// packed as `reversed << 5 | width`. Built once; the writer asks it per symbol
/// and never reverses anything again.
let fixed_table : FixedArray[Int32] = {
  let out = FixedArray::make(288, 0)
  for sym in 0..<288 {
    let (code, width) = fixed_code(sym)
    let mut flipped = 0
    for i in 0..<width {
      flipped = (flipped << 1) | ((code >> i) & 1)
    }
    out[sym] = (flipped << 5) | width
  }
  out
}

///|
/// The five-bit distance codes of a fixed block, reversed the same way.
let fixed_distance : FixedArray[Int32] = {
  let out = FixedArray::make(32, 0)
  for sym in 0..<32 {
    let mut flipped = 0
    for i in 0..<5 {
      flipped = (flipped << 1) | ((sym >> i) & 1)
    }
    out[sym] = flipped
  }
  out
}

///|
/// A table of codes reversed for the stream's bit order, each packed with its
/// width as `reversed << 5 | width`, so that writing one symbol is two shifts and
/// no second lookup.
fn pack_codes(
  codes : FixedArray[Int32],
  widths : FixedArray[Int32],
  n : Int32,
) -> FixedArray[Int32] {
  let out = FixedArray::make(n, 0)
  for sym in 0..<n {
    let width = widths[sym]
    let mut flipped = 0
    for i in 0..<width {
      flipped = (flipped << 1) | ((codes[sym] >> i) & 1)
    }
    out[sym] = (flipped << 5) | width
  }
  out
}

///|
fn emit(bw : BitWriter, sym : Int32) -> Unit {
  let entry = fixed_table[sym]
  bw.bits(entry >> 5, entry & 31)
}

///|
fn emit_match(bw : BitWriter, len : Int32, dist : Int32) -> Unit {
  let li = length_index(len)
  emit(bw, 257 + li)
  if length_extra[li] > 0 {
    bw.bits(len - length_base[li], length_extra[li])
  }
  let dc = distance_index(dist)
  // In a fixed block every distance code is five bits wide.
  bw.bits(fixed_distance[dc], 5)
  if dist_extra[dc] > 0 {
    bw.bits(dist - dist_base[dc], dist_extra[dc])
  }
}

// ------------------------------------------------------------------ the reader

///|
/// Where the decoder is inside the stream.
priv enum Stage {
  Header
  Tables
  TableWidths
  TableBody
  Stored
  Compressed
  Done
}

///|
/// Decompress a raw DEFLATE stream a piece at a time.
///
/// `push` takes whatever has arrived and hands back whatever it decoded;
/// `finish` says no more is coming, and it is an error for the stream to be
/// unfinished when it is called. Between calls the reader holds the input it
/// has not got to yet and nothing else — a response body can be decompressed
/// as it downloads, without the whole of it, or of the output, being held.
///
/// The one-shot [`inflate`] is this reader fed once and finished.
struct Reader {
  br : BitReader
  mut stage : Stage
  mut final_block : Bool
  mut lit : Huffman
  mut dist : Huffman
  /// The nineteen code-length widths, three bits each.
  mut widths : FixedArray[Int32]
  mut nwidths : Int32
  /// The dynamic table under construction: the literal/length widths, then the
  /// distance widths.
  mut lit_widths : FixedArray[Int32]
  mut dist_widths : FixedArray[Int32]
  mut nlit : Int32
  mut ndist : Int32
  mut code_len : Huffman
  /// How far the table under construction has got.
  mut at : Int32
  /// A stored block's payload still to copy.
  mut stored_left : Int32
  limit : Int32
  mut at_end : Bool
  /// Output already handed back, kept as far as a back-reference reaches.
  mut history : Array[Byte]
  /// Output decoded since the last take, in a buffer of its own: a decoder that
  /// pushes every byte through a growable array pays a call and a capacity check
  /// for each one, and there are a great many bytes.
  mut out : FixedArray[Byte]
  mut produced : Int32
}

///|
pub fn Reader::new(limit? : Int32) -> Reader {
  {
    br: BitReader::new(),
    stage: Header,
    final_block: false,
    lit: fixed_litlen,
    dist: fixed_dist,
    widths: FixedArray::make(19, 0),
    nwidths: 0,
    lit_widths: FixedArray::make(1, 0),
    dist_widths: FixedArray::make(1, 0),
    nlit: 0,
    ndist: 0,
    code_len: fixed_dist,
    at: 0,
    stored_left: -1,
    limit: match limit {
      Some(n) => n
      None => -1
    },
    at_end: false,
    history: [],
    out: FixedArray::make(4096, b'\x00'),
    produced: 0,
  }
}

///|
/// Feed a chunk, take the bytes it decoded to.
pub fn Reader::push(
  self : Reader,
  data : BytesView,
) -> Bytes raise @moonzip.Refused {
  self.br.push(data)
  self.decode()
  self.take()
}

///|
/// Input handed to the reader that the DEFLATE stream did not use, and the
/// reader's buffer emptied.
///
/// A container that wraps DEFLATE needs this. The reader stops the moment the
/// last block ends, so a gzip trailer or a second member is still sitting in
/// the buffer — and the container is the only thing that knows what to do with
/// it. `gunzip` takes its eight-byte trailer from here.
pub fn Reader::rest(self : Reader) -> Bytes {
  // A look-ahead may have pulled whole bytes into the accumulator, and a trailer
  // is exactly the kind of thing that lives there: the reader stopped the moment
  // the last block ended, without consuming them. Handing them back first is what
  // makes this answer complete.
  self.br.align()
  let out : Array[Byte] = []
  for i in self.br.pos..<self.br.buf.length() {
    out.push(self.br.buf[i])
  }
  self.br.buf = []
  self.br.pos = 0
  Bytes::from_array(out)
}

///|
/// Whether the last block has been read, which is what a container checks
/// before it looks for a trailer.
pub fn Reader::done(self : Reader) -> Bool {
  self.stage is Done
}

///|
/// Say the stream is complete. An unfinished block is a truncated stream.
pub fn Reader::finish(self : Reader) -> Bytes raise @moonzip.Refused {
  self.at_end = true
  self.decode()
  if self.stage is Done {
    self.take()
  } else {
    raise @moonzip.Truncated(at=self.br.at())
  }
}

///|
fn Reader::take(self : Reader) -> Bytes {
  let made = Bytes::from_array(self.out[0:self.produced])
  self.produced = 0
  // A back-reference may reach 32 KiB back, and those bytes have already been
  // handed to the caller — so that much of what is leaving is kept, exactly as
  // the writer keeps its window. Everything else is the caller's.
  //
  // What is kept is the *tail*, not the whole output: a push that decodes a
  // megabyte used to copy all of it into the history one byte at a time, which
  // doubled the cost of a decode and bought nothing — the bytes before the
  // window are bytes no back-reference can name.
  let total = self.history.length() + made.length()
  let want = if total > window { window } else { total }
  let start = total - want
  let held = self.history.length()
  let kept : Array[Byte] = Array::make(want, b'\x00')
  for i in 0..<want {
    let at = start + i
    kept[i] = if at < held { self.history[at] } else { made[at - held] }
  }
  self.history = kept
  made
}

///|
/// Fold one byte of output in, refusing to pass the caller's bound. A
/// compressed stream says nothing about how far it expands, so a reader
/// handling input from elsewhere says how much it is prepared to hold.
fn Reader::push_out(self : Reader, byte : Byte) -> Unit raise @moonzip.Refused {
  if self.limit >= 0 && self.total() >= self.limit {
    raise @moonzip.TooBig(limit=self.limit)
  }
  self.grow(1)
  self.out.unsafe_set(self.produced, byte)
  self.produced = self.produced + 1
}

///|
/// Room for `want` more bytes of output, doubling the buffer when there is not.
fn Reader::grow(self : Reader, want : Int32) -> Unit {
  let need = self.produced + want
  if need > self.out.length() {
    let mut size = if self.out.length() > 0 { self.out.length() } else { 4096 }
    while size < need {
      size = size * 2
    }
    let next = FixedArray::make(size, b'\x00')
    next.unsafe_blit(0, self.out, 0, self.produced)
    self.out = next
  }
}

///|
/// How much has been decoded in total: what is kept, plus what is waiting to be
/// taken. A back-reference is measured against this, because it reaches back
/// into output that has already left.
fn Reader::total(self : Reader) -> Int32 {
  self.history.length() + self.produced
}

///|
/// One byte of the output so far, wherever it currently lives.
fn Reader::byte_at(self : Reader, i : Int32) -> Byte {
  if i < self.history.length() {
    self.history[i]
  } else {
    self.out.unsafe_get(i - self.history.length())
  }
}

///|
/// The decode loop, which runs as far as the buffered input allows.
///
/// Every step is finished or not started: a step never consumes half of itself
/// and waits. The buffer guard at the top is what makes that true — eight
/// bytes cover the widest thing a step reads, which is a match at fifteen bits
/// of length code, five of extra length, five of distance code and thirteen of
/// extra distance. With fewer than eight bytes buffered and the stream not
/// declared over, the loop stops and waits for the next push.
fn Reader::decode(self : Reader) -> Unit raise @moonzip.Refused {
  while true {
    if self.stage is Done {
      return
    }
    if !self.at_end && self.br.remaining() < 8 {
      return
    }
    match self.stage {
      Header =>
        match self.br.bits(3) {
          None => raise @moonzip.Truncated(at=self.br.at())
          Some(head) => {
            self.final_block = (head & 1) == 1
            match head >> 1 {
              0 => {
                self.br.align()
                self.stored_left = -1
                self.stage = Stored
              }
              1 => {
                self.lit = fixed_litlen
                self.dist = fixed_dist
                self.stage = Compressed
              }
              2 => {
                self.at = 0
                self.stage = Tables
              }
              _ =>
                raise @moonzip.Header(
                  at=self.br.at(),
                  what="a block type DEFLATE does not define",
                )
            }
          }
        }
      Tables => {
        // HLIT, HDIST, HCLEN: how many codes of each kind this block carries.
        let nlit = match self.br.bits(5) {
          None => raise @moonzip.Truncated(at=self.br.at())
          Some(v) => v
        }
        let ndist = match self.br.bits(5) {
          None => raise @moonzip.Truncated(at=self.br.at())
          Some(v) => v
        }
        let ncode = match self.br.bits(4) {
          None => raise @moonzip.Truncated(at=self.br.at())
          Some(v) => v
        }
        self.nlit = nlit + 257
        self.ndist = ndist + 1
        self.nwidths = ncode + 4
        // Fresh widths: a stream may carry any number of dynamic blocks, and
        // each declares its own tables from nothing.
        self.widths = FixedArray::make(19, 0)
        self.lit_widths = FixedArray::make(self.nlit, 0)
        self.dist_widths = FixedArray::make(self.ndist, 0)
        self.at = 0
        self.stage = TableWidths
      }
      TableWidths =>
        // The nineteen code-length widths, three bits each, in the order that
        // puts the ones most likely to be zero last.
        if self.at >= self.nwidths {
          self.code_len = Huffman::of(self.widths, 19)
          self.at = 0
          self.stage = TableBody
        } else {
          match self.br.bits(3) {
            None => raise @moonzip.Truncated(at=self.br.at())
            Some(width) => {
              self.widths[length_order[self.at]] = width
              self.at += 1
            }
          }
        }
      TableBody =>
        // The widths of the two alphabets, run-length coded under the
        // nineteen-symbol code: a width, or a repeat of the previous one, or a
        // run of zeros.
        if self.at >= self.nlit + self.ndist {
          self.lit = Huffman::of(self.lit_widths, self.nlit)
          self.dist = Huffman::of(self.dist_widths, self.ndist)
          self.stage = Compressed
        } else {
          let sym = self.code_len.sym(self.br)
          if sym < 0 {
            raise @moonzip.Truncated(at=self.br.at())
          }
          if sym < 16 {
            self.put_width(sym)
          } else {
            let (repeat, value) = match sym {
              16 => {
                if self.at == 0 {
                  raise @moonzip.Code(at=self.br.at())
                }
                let extra = match self.br.bits(2) {
                  None => raise @moonzip.Truncated(at=self.br.at())
                  Some(v) => v
                }
                (3 + extra, self.width_at(self.at - 1))
              }
              17 => {
                let extra = match self.br.bits(3) {
                  None => raise @moonzip.Truncated(at=self.br.at())
                  Some(v) => v
                }
                (3 + extra, 0)
              }
              _ => {
                let extra = match self.br.bits(7) {
                  None => raise @moonzip.Truncated(at=self.br.at())
                  Some(v) => v
                }
                (11 + extra, 0)
              }
            }
            if self.at + repeat > self.nlit + self.ndist {
              raise @moonzip.Code(at=self.br.at())
            }
            for _ in 0..<repeat {
              self.put_width(value)
            }
          }
        }
      Stored => {
        if self.stored_left < 0 {
          // The length and its complement have not been read yet.
          if self.br.remaining() < 4 {
            raise @moonzip.Truncated(at=self.br.at())
          }
          let len = match self.br.bits(16) {
            None => raise @moonzip.Truncated(at=self.br.at())
            Some(v) => v
          }
          let nlen = match self.br.bits(16) {
            None => raise @moonzip.Truncated(at=self.br.at())
            Some(v) => v
          }
          if len != (nlen ^ 0xFFFF) {
            raise @moonzip.Header(
              at=self.br.at(),
              what="a stored block's length and its complement disagree",
            )
          }
          self.stored_left = len
        }
        self.grow(self.stored_left)
        let took = self.br.take_bytes(self.out, self.produced, self.stored_left)
        self.produced = self.produced + took
        if self.limit >= 0 && self.total() > self.limit {
          raise @moonzip.TooBig(limit=self.limit)
        }
        self.stored_left -= took
        if took == 0 && self.stored_left > 0 {
          // At a byte boundary with nothing buffered and no more coming.
          raise @moonzip.Truncated(at=self.br.at())
        }
        if self.stored_left == 0 {
          if self.final_block {
            self.stage = Done
          } else {
            self.stage = Header
          }
        }
      }
      Compressed => self.codes()
      Done => ()
    }
  }
}

///|
/// Decode symbols until the buffer runs short or the block ends.
///
/// This is one arm of `decode` lifted into its own loop, and the reason is the
/// dispatch it saves: a literal costs one table lookup, and taking it through the
/// stage machine means testing the stage and the buffer guard again for every byte
/// of output. Here the guard is paid once per symbol rather than twice, and the
/// stage is tested only when something might have changed it.
///
/// Everything the loop reads between symbols is a local: the bit state, the two
/// code tables, the output cursor. A field is a load through a pointer this loop's
/// own stores may in principle have changed, so the compiler has to reload it after
/// every byte written — and a per-symbol chain of dependent loads is most of what a
/// decoder's inner loop can lose to.
fn Reader::codes(self : Reader) -> Unit raise @moonzip.Refused {
  let mut out = self.out
  let mut olen = self.produced
  let mut cap = out.length()
  let at_end = self.at_end
  let lit = self.lit
  let dist = self.dist
  let lit_fast = lit.fast
  let lit_sub = lit.sub
  let dist_fast = dist.fast
  let dist_sub = dist.sub
  let br = self.br
  let buf = br.buf
  let n = buf.length()
  let limit = self.limit
  let kept = self.history.length()
  let mut pos = br.pos
  let mut acc = br.acc
  let mut held = br.held
  let mut have = kept + olen
  let mut running = true
  while running && (at_end || n - pos >= 8) {
    // Eight bytes at a time. One unaligned load leaves the accumulator holding a
    // code of any width plus the extra bits that follow it, so a symbol costs a
    // shift and a lookup rather than a refill per field.
    if held < 56 && n - pos >= 8 {
      let word = buf.unsafe_read_uint64_le(pos)
      let take = (63 - held) >> 3
      let after = held + take * 8
      acc = (acc | (word << held)) & ((1UL << after) - 1UL)
      pos += take
      held = after
    }
    let entry = if held >= FAST_BITS {
      lit_fast.unsafe_get(acc.to_int() & FAST_MASK)
    } else {
      -1
    }
    let mut sym = entry >> 4
    let mut known = entry >= 0
    if known {
      let width = entry & 0xF
      acc = acc >> width
      held -= width
    } else if entry < -1 && held >= 15 {
      // A code the look-ahead only begins: its tail decides which one it is.
      let tail = lit_sub.unsafe_get(
        -entry - 2 + ((acc.to_int() >> FAST_BITS) & (SUB_SIZE - 1)),
      )
      if tail >= 0 {
        let width = tail & 0xF
        acc = acc >> width
        held -= width
        sym = tail >> 4
        known = true
      }
    }
    if !known {
      // A code longer than the look-ahead, or an accumulator holding fewer bits
      // than one. Rare enough that the call and the state hand-off are cheaper
      // than keeping a second table for it.
      br.pos = pos
      br.acc = acc
      br.held = held
      sym = lit.sym(br)
      pos = br.pos
      acc = br.acc
      held = br.held
      if sym < 0 {
        raise @moonzip.Truncated(at=pos)
      }
    }
    if sym < 256 {
      // The common case, and the one this loop exists for: with no limit there
      // is nothing to check, and the check costs a call per output byte.
      if limit < 0 {
        if olen >= cap {
          self.produced = olen
          self.grow(1)
          out = self.out
          cap = out.length()
        }
        out.unsafe_set(olen, sym.to_byte())
        olen = olen + 1
      } else {
        // The slow path counts against the limit and so goes through the reader,
        // whose output cursor is the field: hand the local one over first.
        br.pos = pos
        br.acc = acc
        br.held = held
        self.produced = olen
        self.push_out(sym.to_byte())
        olen = self.produced
        pos = br.pos
        acc = br.acc
        held = br.held
      }
      have += 1
    } else if sym == 256 {
      running = false
      self.stage = if self.final_block { Done } else { Header }
    } else {
      let index = sym - 257
      if index >= 29 {
        br.pos = pos
        raise @moonzip.Code(at=pos)
      }
      let info = length_info.unsafe_get(index)
      let need = info & 31
      let len = if need > 0 {
        if held < need {
          br.pos = pos
          br.acc = acc
          br.held = held
          let extra = br.take(need)
          if extra < 0 {
            raise @moonzip.Truncated(at=br.at())
          }
          pos = br.pos
          acc = br.acc
          held = br.held
          (info >> 5) + extra
        } else {
          let value = (info >> 5) + (acc.to_int() & ((1 << need) - 1))
          acc = acc >> need
          held -= need
          value
        }
      } else {
        info >> 5
      }
      let dentry = if held >= FAST_BITS {
        dist_fast.unsafe_get(acc.to_int() & FAST_MASK)
      } else {
        -1
      }
      let mut dcode = dentry >> 4
      let mut dknown = dentry >= 0
      if dknown {
        let width = dentry & 0xF
        acc = acc >> width
        held -= width
      } else if dentry < -1 && held >= 15 {
        let tail = dist_sub.unsafe_get(
          -dentry - 2 + ((acc.to_int() >> FAST_BITS) & (SUB_SIZE - 1)),
        )
        if tail >= 0 {
          let width = tail & 0xF
          acc = acc >> width
          held -= width
          dcode = tail >> 4
          dknown = true
        }
      }
      if !dknown {
        br.pos = pos
        br.acc = acc
        br.held = held
        dcode = dist.sym(br)
        pos = br.pos
        acc = br.acc
        held = br.held
        if dcode < 0 {
          raise @moonzip.Truncated(at=pos)
        }
      }
      if dcode >= 30 {
        br.pos = pos
        raise @moonzip.Code(at=pos)
      }
      let dinfo = distance_info.unsafe_get(dcode)
      let dneed = dinfo & 31
      let mut back = dinfo >> 5
      if dneed > 0 {
        if held < dneed {
          br.pos = pos
          br.acc = acc
          br.held = held
          let extra = br.take(dneed)
          if extra < 0 {
            raise @moonzip.Truncated(at=br.at())
          }
          pos = br.pos
          acc = br.acc
          held = br.held
          back += extra
        } else {
          back += acc.to_int() & ((1 << dneed) - 1)
          acc = acc >> dneed
          held -= dneed
        }
      }
      // One measurement of how much has been produced, used for all three
      // questions the copy asks: is the distance in range, where does the copy
      // start, and would it run past the limit.
      if back > have {
        br.pos = pos
        raise @moonzip.Distance(at=pos)
      }
      let start = have - back
      if (limit < 0 || have + len <= limit) && start >= kept {
        let base = start - kept
        if olen + len > cap {
          self.produced = olen
          self.grow(len)
          out = self.out
          cap = out.length()
        }
        // A match that does not overlap itself is a block copy, and taking it in
        // one go is most of what a long match costs here. A shorter one, or one
        // that repeats a pattern shorter than eight bytes, is copied a byte at a
        // time because the bytes it copies are the ones it is writing.
        if back >= len && len >= 16 {
          out.unsafe_blit(olen, out, base, len)
        } else {
          for k in 0..<len {
            out.unsafe_set(olen + k, out.unsafe_get(base + k))
          }
        }
        olen = olen + len
        have += len
      } else {
        br.pos = pos
        br.acc = acc
        br.held = held
        self.produced = olen
        let mut k = 0
        while k < len {
          self.push_out(self.byte_at(start + k))
          k += 1
        }
        olen = self.produced
        pos = br.pos
        acc = br.acc
        held = br.held
        have += len
      }
    }
  }
  br.pos = pos
  br.acc = acc
  br.held = held
  self.produced = olen
}

///|
/// One width of the dynamic table: the literal/length widths come first, then
/// the distance widths.
fn Reader::width_at(self : Reader, i : Int32) -> Int32 {
  if i < self.nlit {
    self.lit_widths[i]
  } else {
    self.dist_widths[i - self.nlit]
  }
}

///|
/// Put one width where it belongs and step along.
fn Reader::put_width(self : Reader, width : Int32) -> Unit {
  if self.at < self.nlit {
    self.lit_widths[self.at] = width
  } else {
    self.dist_widths[self.at - self.nlit] = width
  }
  self.at += 1
}
