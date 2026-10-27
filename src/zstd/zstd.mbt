// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The four-byte magic, little-endian: `0xFD2FB528`.
let magic : FixedArray[Int32] = [0x28, 0xB5, 0x2F, 0xFD]

///|
/// Literal length codes 16 and up carry extra bits; below that the code *is* the
/// length.
let literals_base : FixedArray[Int32] = [
  16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192,
  16384, 32768, 65536,
]

///|
let literals_extra : FixedArray[Int32] = [
  1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
]

///|
/// Match lengths start at three, which is why the first thirty-two codes need no
/// table at all.
let match_base : FixedArray[Int32] = [
  35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195,
  16387, 32771, 65539,
]

///|
let match_extra : FixedArray[Int32] = [
  1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
]

///|
/// A frame in progress: what the blocks so far have produced, and the state that
/// carries between blocks.
///
/// The three repeat offsets and the four decoding tables are the whole of the
/// cross-block state in zstd, which is why a block cannot be decoded alone.
priv struct Frame {
  out : Array[Byte]
  window : Int32
  repeats : Array[Int32]
  mut literals_tree : Tree?
  mut ll_table : Table?
  mut of_table : Table?
  mut ml_table : Table?
}

///|
/// Decompress a zstd frame.
///
/// ```moonbit nocheck
/// let plain = @zstd.unzstd(packed[:])
/// ```
pub fn unzstd(data : BytesView, limit? : Int32) -> Bytes raise @moonzip.Refused {
  let bound = match limit {
    Some(n) => n
    None => -1
  }
  let out : Array[Byte] = []
  let mut at = 0
  // Concatenated frames are legal, and so are skippable ones, so this is a loop
  // rather than a single frame.
  while at < data.length() {
    if data.length() - at < 4 {
      raise @moonzip.Truncated(at~)
    }
    let tag = read32(data, at)
    if tag >= 0x184D2A50U && tag <= 0x184D2A5FU {
      // A skippable frame: a user-data blob. Step over it.
      if at + 8 > data.length() {
        raise @moonzip.Truncated(at~)
      }
      let size = read32(data, at + 4).reinterpret_as_int()
      if size < 0 || at + 8 + size > data.length() {
        raise @moonzip.Truncated(at~)
      }
      at = at + 8 + size
      continue
    }
    if tag != 0xFD2FB528U {
      raise @moonzip.Header(at~, what="this is not a zstd frame")
    }
    let made = one_frame(data, at + 4, bound)
    at = made.1
    for b in made.0 {
      out.push(b)
    }
    if bound >= 0 && out.length() > bound {
      raise @moonzip.TooBig(limit=bound)
    }
  }
  Bytes::from_array(out)
}

///|
fn read32(data : BytesView, at : Int32) -> UInt32 {
  data[at].to_uint() |
  (data[at + 1].to_uint() << 8) |
  (data[at + 2].to_uint() << 16) |
  (data[at + 3].to_uint() << 24)
}

///|
/// One frame, from just after its magic. Returns the output and where it ended.
fn one_frame(
  data : BytesView,
  start : Int32,
  limit : Int32,
) -> (Bytes, Int32) raise @moonzip.Refused {
  let mut at = start
  if at >= data.length() {
    raise @moonzip.Truncated(at~)
  }
  let descriptor = data[at].to_int()
  at += 1
  if (descriptor & 0x08) != 0 {
    raise @moonzip.Header(at=start, what="a reserved bit that must be zero")
  }
  let fcs_flag = descriptor >> 6
  let single_segment = (descriptor & 0x20) != 0
  let checksum = (descriptor & 0x04) != 0
  let dict_flag = descriptor & 0x03
  let mut window = 0
  if !single_segment {
    if at >= data.length() {
      raise @moonzip.Truncated(at~)
    }
    let byte = data[at].to_int()
    at += 1
    let exponent = byte >> 3
    let mantissa = byte & 7
    let base = 1 << (10 + exponent)
    window = base + base / 8 * mantissa
  }
  let dict_size = match dict_flag {
    0 => 0
    1 => 1
    2 => 2
    _ => 4
  }
  for _ in 0..<dict_size {
    if at >= data.length() {
      raise @moonzip.Truncated(at~)
    }
    // A dictionary needs bytes this package does not have; a frame that names one
    // cannot be decoded correctly without it, so saying so is the honest answer.
    if data[at].to_int() != 0 {
      raise @moonzip.Header(
        at~,
        what="a frame that needs a dictionary, which this package cannot supply",
      )
    }
    at += 1
  }
  let fcs_size = match fcs_flag {
    0 => if single_segment { 1 } else { 0 }
    1 => 2
    2 => 4
    _ => 8
  }
  let mut content_size = 0L
  for i in 0..<fcs_size {
    content_size = content_size | (data[at].to_int().to_int64() << (i * 8))
    at += 1
  }
  if fcs_size == 2 {
    content_size = content_size + 256L
  }
  if single_segment {
    window = content_size.to_int()
  }
  if window < 1024 {
    window = 1024
  }
  let frame = Frame::{
    out: [],
    window,
    repeats: [1, 4, 8],
    literals_tree: None,
    ll_table: None,
    of_table: None,
    ml_table: None,
  }
  let mut last = false
  while !last {
    if at + 3 > data.length() {
      raise @moonzip.Truncated(at~)
    }
    let header = data[at].to_int() |
      (data[at + 1].to_int() << 8) |
      (data[at + 2].to_int() << 16)
    at += 3
    last = (header & 1) != 0
    let kind = (header >> 1) & 3
    let size = header >> 3
    if kind == 0 {
      if at + size > data.length() {
        raise @moonzip.Truncated(at~)
      }
      for i in 0..<size {
        frame.out.push(data[at + i])
      }
      at += size
    } else if kind == 1 {
      if at >= data.length() {
        raise @moonzip.Truncated(at~)
      }
      let byte = data[at]
      at += 1
      for _ in 0..<size {
        frame.out.push(byte)
      }
    } else if kind == 2 {
      if at + size > data.length() {
        raise @moonzip.Truncated(at~)
      }
      decode_block(frame, data[at:at + size])
      at += size
    } else {
      raise @moonzip.Header(
        at=at - 3,
        what="a block type the format does not define",
      )
    }
    if limit >= 0 && frame.out.length() > limit {
      raise @moonzip.TooBig(limit~)
    }
  }
  if content_size > 0L && frame.out.length().to_int64() != content_size {
    raise @moonzip.Length(
      want=content_size.to_int().reinterpret_as_uint(),
      got=frame.out.length(),
    )
  }
  if checksum {
    if at + 4 > data.length() {
      raise @moonzip.Truncated(at~)
    }
    let want = read32(data, at)
    at += 4
    let got = @moonzip.crc32(Bytes::from_array(frame.out)[:])
    if want != got {
      raise @moonzip.Checksum(want~, got~)
    }
  }
  (Bytes::from_array(frame.out), at)
}

///|
/// A compressed block: literals first, then the sequences that place them.
fn decode_block(
  frame : Frame,
  block : BytesView,
) -> Unit raise @moonzip.Refused {
  let (literals, used) = read_literals(frame, block)
  let mut at = used
  if at >= block.length() {
    // A block with no sequences section at all: everything is literals.
    for b in literals {
      frame.out.push(b)
    }
    return
  }
  let first = block[at].to_int()
  let mut count = 0
  if first < 128 {
    count = first
    at += 1
  } else if first < 255 {
    if at + 1 >= block.length() {
      raise @moonzip.Truncated(at~)
    }
    count = ((first - 128) << 8) + block[at + 1].to_int()
    at += 2
  } else {
    if at + 2 >= block.length() {
      raise @moonzip.Truncated(at~)
    }
    count = block[at + 1].to_int() + (block[at + 2].to_int() << 8) + 0x7F00
    at += 3
  }
  if count == 0 {
    for b in literals {
      frame.out.push(b)
    }
    return
  }
  if at >= block.length() {
    raise @moonzip.Truncated(at~)
  }
  let modes = block[at].to_int()
  at += 1
  if (modes & 0x03) != 0 {
    raise @moonzip.Header(
      at=at - 1,
      what="a sequence header with reserved bits set",
    )
  }
  let ll_mode = (modes >> 6) & 3
  let of_mode = (modes >> 4) & 3
  let ml_mode = (modes >> 2) & 3
  let ll_made = read_table(frame.ll_table, ll_mode, block, at, 9, PredefinedLl)
  frame.ll_table = Some(ll_made.0)
  at = ll_made.1
  let of_made = read_table(frame.of_table, of_mode, block, at, 8, PredefinedOf)
  frame.of_table = Some(of_made.0)
  at = of_made.1
  let ml_made = read_table(frame.ml_table, ml_mode, block, at, 9, PredefinedMl)
  frame.ml_table = Some(ml_made.0)
  at = ml_made.1
  let ll = match frame.ll_table {
    Some(t) => t
    None =>
      raise @moonzip.Header(
        at~,
        what="a sequence with no literals-length table",
      )
  }
  let of_ = match frame.of_table {
    Some(t) => t
    None => raise @moonzip.Header(at~, what="a sequence with no offset table")
  }
  let ml = match frame.ml_table {
    Some(t) => t
    None =>
      raise @moonzip.Header(at~, what="a sequence with no match-length table")
  }
  let bits = Rev::new(block[at:])
  let mut ll_state = ll.initial(bits)
  let mut of_state = of_.initial(bits)
  let mut ml_state = ml.initial(bits)
  let mut literals_at = 0
  for index in 0..<count {
    let offset_code = of_.symbol(of_state)
    let offset_value = (1 << offset_code) + bits.take(offset_code)
    let match_code = ml.symbol(ml_state)
    let match_length = if match_code < 32 {
      match_code + 3
    } else {
      match_base[match_code - 32] + bits.take(match_extra[match_code - 32])
    }
    let lit_code = ll.symbol(ll_state)
    let lit_length = if lit_code < 16 {
      lit_code
    } else {
      literals_base[lit_code - 16] + bits.take(literals_extra[lit_code - 16])
    }
    // The literals for this sequence, then the match it points at.
    if literals_at + lit_length > literals.length() {
      raise @moonzip.Header(
        at~,
        what="a sequence that wants more literals than the block has",
      )
    }
    for k in 0..<lit_length {
      frame.out.push(literals[literals_at + k])
    }
    literals_at += lit_length
    let distance = resolve_offset(frame.repeats, offset_value, lit_length)
    if distance <= 0 || distance > frame.out.length() {
      raise @moonzip.Distance(at=frame.out.length())
    }
    if distance > frame.window {
      raise @moonzip.Distance(at=frame.out.length())
    }
    let from = frame.out.length() - distance
    for k in 0..<match_length {
      // Byte at a time, because a match may overlap itself: the copy is what
      // makes "aaaa" compress to a length and a distance.
      let byte = frame.out[from + k]
      frame.out.push(byte)
    }
    if index + 1 < count {
      ll_state = ll.step(ll_state, bits)
      ml_state = ml.step(ml_state, bits)
      of_state = of_.step(of_state, bits)
    }
  }
  // Whatever literals are left over end the block.
  while literals_at < literals.length() {
    frame.out.push(literals[literals_at])
    literals_at += 1
  }
}

///|
/// Which repeat offset a sequence means, and the new history after it.
///
/// A literals length of zero shifts the meaning of the three small offset values
/// by one, so that "the previous distance" and "the one before that" stay
/// reachable when there are no literals in between — which is how a run of
/// matches at rotating distances is encoded.
fn resolve_offset(
  repeats : Array[Int32],
  offset_value : Int32,
  literals : Int32,
) -> Int32 {
  if offset_value > 3 {
    let distance = offset_value - 3
    repeats[2] = repeats[1]
    repeats[1] = repeats[0]
    repeats[0] = distance
    return distance
  }
  if literals > 0 {
    let index = offset_value - 1
    let distance = repeats[index]
    // Move the used one to the front, shifting the ones before it back.
    let mut k = index
    while k > 0 {
      repeats[k] = repeats[k - 1]
      k -= 1
    }
    repeats[0] = distance
    return distance
  }
  if offset_value == 3 {
    // The special case: "repeat1 minus one", for a run whose distance shrank by
    // one byte at the block boundary.
    let distance = repeats[0] - 1
    if distance <= 0 {
      return -1
    }
    repeats[2] = repeats[1]
    repeats[1] = repeats[0]
    repeats[0] = distance
    return distance
  }
  let index = offset_value
  let distance = repeats[index]
  let mut k = index
  while k > 0 {
    repeats[k] = repeats[k - 1]
    k -= 1
  }
  repeats[0] = distance
  distance
}

///|
/// Which of the three predefined tables a mode means when it asks for one.
priv enum Predefined {
  PredefinedLl
  PredefinedOf
  PredefinedMl
}

///|
/// A table from a compression mode: stated, one symbol, described, or repeated.
fn read_table(
  previous : Table?,
  mode : Int32,
  block : BytesView,
  at : Int32,
  max_log : Int32,
  which : Predefined,
) -> (Table, Int32) raise @moonzip.Refused {
  match mode {
    0 =>
      (
        match which {
          PredefinedLl => predefined_literals_length()
          PredefinedOf => predefined_offset()
          PredefinedMl => predefined_match_length()
        },
        at,
      )
    1 => {
      if at >= block.length() {
        raise @moonzip.Truncated(at~)
      }
      let symbol = block[at].to_int()
      (Table::single(symbol, 6), at + 1)
    }
    2 => {
      if at >= block.length() {
        raise @moonzip.Truncated(at~)
      }
      let (dist, used) = Dist::read(block[at:])
      if dist.log > max_log {
        raise @moonzip.Header(
          at~,
          what="a probability table scaled past its limit",
        )
      }
      (Table::build(dist), at + used)
    }
    _ =>
      match previous {
        Some(table) => (table, at)
        None =>
          raise @moonzip.Header(
            at~,
            what="a repeat of a table that has not been sent yet",
          )
      }
  }
}

///|
/// The literals section: raw bytes, one repeated byte, or Huffman-coded streams.
fn read_literals(
  frame : Frame,
  block : BytesView,
) -> (Bytes, Int32) raise @moonzip.Refused {
  if block.length() == 0 {
    raise @moonzip.Truncated(at=0)
  }
  let first = block[0].to_int()
  let kind = first & 3
  let format = (first >> 2) & 3
  if kind == 0 || kind == 1 {
    let mut size = 0
    let mut header = 0
    if format == 0 || format == 2 {
      size = first >> 3
      header = 1
    } else if format == 1 {
      if block.length() < 2 {
        raise @moonzip.Truncated(at=0)
      }
      size = (first >> 4) + (block[1].to_int() << 4)
      header = 2
    } else {
      if block.length() < 3 {
        raise @moonzip.Truncated(at=0)
      }
      size = (first >> 4) + (block[1].to_int() << 4) + (block[2].to_int() << 12)
      header = 3
    }
    if kind == 0 {
      if header + size > block.length() {
        raise @moonzip.Truncated(at=0)
      }
      return (block[header:header + size].to_owned(), header + size)
    }
    if header >= block.length() {
      raise @moonzip.Truncated(at=0)
    }
    let byte = block[header]
    let out : Array[Byte] = []
    for _ in 0..<size {
      out.push(byte)
    }
    return (Bytes::from_array(out), header + 1)
  }
  // Huffman-coded. Four streams when the sizes are large enough to need them.
  let mut regenerated = 0
  let mut compressed = 0
  let mut header = 0
  if format == 0 || format == 1 {
    if block.length() < 3 {
      raise @moonzip.Truncated(at=0)
    }
    regenerated = (first >> 4) | ((block[1].to_int() & 0x3F) << 4)
    compressed = (block[1].to_int() >> 6) | (block[2].to_int() << 2)
    header = 3
  } else if format == 2 {
    if block.length() < 4 {
      raise @moonzip.Truncated(at=0)
    }
    regenerated = (first >> 4) |
      (block[1].to_int() << 4) |
      ((block[2].to_int() & 0x03) << 12)
    compressed = ((block[2].to_int() >> 2) | (block[3].to_int() << 6)) & 0x3FFF
    header = 4
  } else {
    if block.length() < 5 {
      raise @moonzip.Truncated(at=0)
    }
    regenerated = (first >> 4) |
      (block[1].to_int() << 4) |
      ((block[2].to_int() & 0x3F) << 12)
    compressed = (
        (block[2].to_int() >> 6) |
        (block[3].to_int() << 2) |
        (block[4].to_int() << 10)
      ) &
      0x3FFFF
    header = 5
  }
  if header + compressed > block.length() {
    raise @moonzip.Truncated(at=0)
  }
  let section = block[header:header + compressed]
  let mut offset = 0
  let tree = if kind == 2 {
    let made = Tree::read(section)
    offset = made.1
    frame.literals_tree = Some(made.0)
    made.0
  } else {
    match frame.literals_tree {
      Some(t) => t
      None =>
        raise @moonzip.Header(
          at=0,
          what="a literals block that reuses a tree that was never sent",
        )
    }
  }
  if format == 0 {
    // One stream.
    return (
      decode_literals(section[offset:], regenerated, tree),
      header + compressed,
    )
  }
  // Four streams: three sizes stated, the fourth implied.
  if offset + 6 > section.length() {
    raise @moonzip.Truncated(at=0)
  }
  let s1 = section[offset].to_int() | (section[offset + 1].to_int() << 8)
  let s2 = section[offset + 2].to_int() | (section[offset + 3].to_int() << 8)
  let s3 = section[offset + 4].to_int() | (section[offset + 5].to_int() << 8)
  let total = section.length() - offset - 6
  let s4 = total - s1 - s2 - s3
  if s4 < 1 {
    raise @moonzip.Header(
      at=0,
      what="a literals jump table that does not fit its own block",
    )
  }
  let each = (regenerated + 3) / 4
  let out : Array[Byte] = []
  let mut cursor = offset + 6
  let sizes : Array[Int32] = [s1, s2, s3, s4]
  let counts : Array[Int32] = [each, each, each, regenerated - each * 3]
  for i in 0..<4 {
    let piece = decode_literals(
      section[cursor:cursor + sizes[i]],
      counts[i],
      tree,
    )
    for b in piece {
      out.push(b)
    }
    cursor += sizes[i]
  }
  (Bytes::from_array(out), header + compressed)
}
