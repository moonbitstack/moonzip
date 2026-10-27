// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How much input one block takes. The format allows 128 KiB; a smaller block
/// keeps the match finder's window inside what a single frame segment can hold.
let block_limit : Int32 = 65536

///|
/// One match found in a block: how many literals come first, how long the match
/// is, and how far back it reaches.
priv struct Seq {
  literals : Int32
  length : Int32
  offset : Int32
}

///|
/// Compress into a zstd frame.
///
/// ```moonbit nocheck
/// let packed = @zstd.zstd(body[:])
/// ```
///
/// The block is an LZ77 parse coded with the *predefined* FSE tables, and the
/// literals are sent raw. That is a legal frame that any decoder reads, and it
/// compresses: what it gives up against `zstd -19` is the per-block table
/// selection and the Huffman coding of literals, which are the two parts of the
/// reference encoder that are about ratio rather than about the format.
pub fn zstd(data : BytesView, level~ : Int32 = 3) -> Bytes {
  let out : Array[Byte] = []
  for b in magic {
    out.push(b.to_byte())
  }
  // A single segment means the window is the content size, so no window
  // descriptor is written and the distance a match may reach is bounded by the
  // frame itself.
  let size = data.length()
  let fcs_flag = if size < 256 {
    0
  } else if size < 65536 + 256 {
    1
  } else if size.to_int64() < 4294967296L {
    2
  } else {
    3
  }
  out.push((((fcs_flag << 6) | 0x20) & 0xFF).to_byte())
  match fcs_flag {
    0 => out.push(size.to_byte())
    1 => {
      let shifted = size - 256
      out.push((shifted & 0xFF).to_byte())
      out.push(((shifted >> 8) & 0xFF).to_byte())
    }
    2 =>
      for i in 0..<4 {
        out.push(((size >> (i * 8)) & 0xFF).to_byte())
      }
    _ =>
      for i in 0..<8 {
        out.push(((size.to_int64() >> (i * 8)) & 0xFFL).to_int().to_byte())
      }
  }
  let mut at = 0
  let mut first = true
  while at < size || first {
    first = false
    let stop = if size - at < block_limit { size } else { at + block_limit }
    let last = stop >= size
    let block = data[at:stop]
    let packed = compress_block(block, level)
    let raw_is_smaller = packed.length() >= block.length()
    if raw_is_smaller {
      let header = (if last { 1 } else { 0 }) | (block.length() << 3)
      for i in 0..<3 {
        out.push(((header >> (i * 8)) & 0xFF).to_byte())
      }
      for b in block {
        out.push(b)
      }
    } else {
      let header = (if last { 1 } else { 0 }) |
        (2 << 1) |
        (packed.length() << 3)
      for i in 0..<3 {
        out.push(((header >> (i * 8)) & 0xFF).to_byte())
      }
      for b in packed {
        out.push(b)
      }
    }
    at = stop
  }
  Bytes::from_array(out)
}

///|
/// A literal length as the code byte the format wants.
fn literals_code(length : Int32) -> Int32 {
  if length < 16 {
    return length
  }
  let mut i = 0
  while i < 20 {
    let base = literals_base[i]
    if length >= base && length < base + (1 << literals_extra[i]) {
      return 16 + i
    }
    i += 1
  }
  35
}

///|
fn literals_value(length : Int32) -> Int32 {
  let code = literals_code(length)
  if code < 16 {
    return 0
  }
  length - literals_base[code - 16]
}

///|
fn match_code(length : Int32) -> Int32 {
  if length < 35 {
    return length - 3
  }
  let mut i = 0
  while i < 21 {
    let base = match_base[i]
    if length >= base && length < base + (1 << match_extra[i]) {
      return 32 + i
    }
    i += 1
  }
  52
}

///|
fn match_value(length : Int32) -> Int32 {
  let code = match_code(length)
  if code < 32 {
    return 0
  }
  length - match_base[code - 32]
}

///|
/// Parse a block into sequences, greedily, with a hash chain.
///
/// Nothing clever: the encoder's job here is to produce a valid, compressed
/// frame, and the reference's optimal parser is a project of its own.
fn parse(block : BytesView, depth : Int32) -> (Array[Byte], Array[Seq]) {
  let n = block.length()
  let literals : Array[Byte] = []
  let seqs : Array[Seq] = []
  let bits = 15
  let table_size = 1 << bits
  let head = Array::make(table_size, -1)
  let prev = Array::make(if n > 0 { n } else { 1 }, -1)
  let mut pending_literals = 0
  let mut i = 0
  let max_distance = if n < 65535 { n } else { 65535 }
  while i < n {
    let mut matched = 0
    let mut distance = 0
    if i + 4 <= n {
      let hash = hash4(block, i)
      let mut candidate = head[hash]
      let mut tries = 0
      while candidate >= 0 && tries < depth {
        tries += 1
        let back = i - candidate
        if back > max_distance {
          break
        }
        if block[candidate] == block[i] && block[candidate + 1] == block[i + 1] {
          let cap = if n - i < 131074 { n - i } else { 131074 }
          let mut length = 0
          while length < cap && block[candidate + length] == block[i + length] {
            length += 1
          }
          if length > matched {
            matched = length
            distance = back
          }
          if matched >= 64 {
            break
          }
        }
        candidate = prev[candidate]
      }
      // Feed every position into the chain, matched or not, or a later position
      // loses the match this one just used.
      prev[i] = head[hash]
      head[hash] = i
    }
    if matched >= 3 {
      seqs.push({
        literals: pending_literals,
        length: matched,
        offset: distance,
      })
      pending_literals = 0
      let mut k = 1
      while k < matched {
        let at = i + k
        if at + 4 <= n {
          let hash = hash4(block, at)
          prev[at] = head[hash]
          head[hash] = at
        }
        k += 1
      }
      i += matched
    } else {
      literals.push(block[i])
      pending_literals += 1
      i += 1
    }
  }
  for k in i..<n {
    literals.push(block[k])
    pending_literals += 1
  }
  (literals, seqs)
}

///|
fn hash4(block : BytesView, at : Int32) -> Int32 {
  let word = block[at].to_uint() |
    (block[at + 1].to_uint() << 8) |
    (block[at + 2].to_uint() << 16) |
    (block[at + 3].to_uint() << 24)
  ((word * 2654435761U) >> 17).reinterpret_as_int() & 0x7FFF
}

///|
/// One compressed block: a literals section and a sequences section.
fn compress_block(block : BytesView, level : Int32) -> Bytes {
  let depth = if level < 1 { 1 } else if level > 9 { 32 } else { level * 3 }
  let (literals, seqs) = parse(block, depth)
  let out : Array[Byte] = []
  // Literals, raw. Three header shapes, by size.
  let count = literals.length()
  if count < 32 {
    out.push(((count << 3) | 0x00).to_byte())
  } else if count < 4096 {
    out.push(((((count & 0x0F) << 4) | 0x04) & 0xFF).to_byte())
    out.push(((count >> 4) & 0xFF).to_byte())
  } else {
    out.push(((((count & 0x0F) << 4) | 0x0C) & 0xFF).to_byte())
    out.push(((count >> 4) & 0xFF).to_byte())
    out.push(((count >> 12) & 0xFF).to_byte())
  }
  for b in literals {
    out.push(b)
  }
  // Sequences. Nothing to say is one byte.
  let nseq = seqs.length()
  if nseq == 0 {
    out.push(b'\x00')
    return Bytes::from_array(out)
  }
  if nseq < 128 {
    out.push(nseq.to_byte())
  } else {
    out.push((0x80 | ((nseq >> 8) & 0x7F)).to_byte())
    out.push((nseq & 0xFF).to_byte())
  }
  // All three tables predefined, which needs no table data at all.
  out.push(b'\x00')
  let stream = write_sequences(seqs)
  for b in stream {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// The sequence bitstream.
///
/// Written back to front, because the decoder reads front to back from the other
/// end: the last thing written is the first thing it sees. The final states are
/// flushed last for the same reason.
fn write_sequences(seqs : Array[Seq]) -> Bytes {
  let ll = predefined_ctable_ll()
  let ml = predefined_ctable_ml()
  let of_ = predefined_ctable_of()
  let bits = Fwd::new()
  let last = seqs.length() - 1
  // Seeded from the last sequence, which is the first one a reader decodes and
  // the only one whose state update it does not read.
  let state_ll = CState::init_for(ll, literals_code(seqs[last].literals))
  let state_ml = CState::init_for(ml, match_code(seqs[last].length))
  let state_of = CState::init_for(of_, highbit(seqs[last].offset + 3))
  // The first sequence's extra bits, then every earlier sequence's symbols and
  // extra bits.
  let tail = seqs[last]
  let ll_code = literals_code(tail.literals)
  let ml_code = match_code(tail.length)
  let of_value = tail.offset + 3
  let of_code = highbit(of_value)
  bits.take(
    literals_value(tail.literals),
    if ll_code < 16 {
      0
    } else {
      literals_extra[ll_code - 16]
    },
  )
  bits.take(
    match_value(tail.length),
    if ml_code < 32 {
      0
    } else {
      match_extra[ml_code - 32]
    },
  )
  bits.take(of_value - (1 << of_code), of_code)
  let mut n = seqs.length() - 1
  while n > 0 {
    n -= 1
    let seq = seqs[n]
    let ll_code = literals_code(seq.literals)
    let ml_code = match_code(seq.length)
    let of_value = seq.offset + 3
    let of_code = highbit(of_value)
    state_of.encode(bits, of_, of_code)
    state_ml.encode(bits, ml, ml_code)
    state_ll.encode(bits, ll, ll_code)
    bits.take(
      literals_value(seq.literals),
      if ll_code < 16 {
        0
      } else {
        literals_extra[ll_code - 16]
      },
    )
    bits.take(
      match_value(seq.length),
      if ml_code < 32 {
        0
      } else {
        match_extra[ml_code - 32]
      },
    )
    bits.take(of_value - (1 << of_code), of_code)
  }
  state_ml.flush(bits, ml)
  state_of.flush(bits, of_)
  state_ll.flush(bits, ll)
  bits.finish()
}

///|
/// The three predefined tables, as the encoder needs them.
fn predefined_ctable_ll() -> CTable {
  let counts : Array[Int32] = [
    4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3,
    2, 1, 1, 1, 1, 1, -1, -1, -1, -1,
  ]
  CTable::build(counts, 6)
}

///|
fn predefined_ctable_ml() -> CTable {
  let counts : Array[Int32] = [
    1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
    -1, -1,
  ]
  CTable::build(counts, 6)
}

///|
fn predefined_ctable_of() -> CTable {
  let counts : Array[Int32] = [
    1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
    -1, -1, -1,
  ]
  CTable::build(counts, 5)
}
