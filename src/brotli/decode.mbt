// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The tables one meta-block installs: how many block types each of the three
/// streams has, the codes that pick them, the prefix codes themselves, and the
/// context map that connects a literal's neighbourhood to a code.
///
/// A meta-block is the unit brotli switches models in, so all of this is thrown
/// away at the end of one and read again at the start of the next. That is why it
/// is a struct rather than fields on the reader.
priv struct Frame {
  /// Literal, command, distance.
  blocks : FixedArray[Int32]
  /// Symbols left in the current block of each stream.
  length : FixedArray[Int32]
  /// Last two block types per stream: [second last, last].
  recent : FixedArray[Int32]
  types : Array[Code]
  sizes : Array[Code]
  literals : Array[Code]
  commands : Array[Code]
  distances : Array[Code]
  /// 64 entries per literal block type.
  mut context : FixedArray[Int32]
  /// 4 entries per distance block type.
  mut distance_context : FixedArray[Int32]
  mut modes : FixedArray[Int32]
  /// True when a literal block type sends every context to one code, which lets
  /// the reader skip the context lookup entirely.
  mut flat : FixedArray[Bool]
  mut distance_codes : Distances
}

///|
fn Frame::new() -> Frame {
  {
    blocks: FixedArray::make(3, 1),
    length: FixedArray::make(3, 1 << 24),
    recent: [1, 0, 1, 0, 1, 0],
    types: [],
    sizes: [],
    literals: [],
    commands: [],
    distances: [],
    context: FixedArray::make(0, 0),
    distance_context: FixedArray::make(0, 0),
    modes: FixedArray::make(0, 0),
    flat: FixedArray::make(0, false),
    distance_codes: distances(0, 0, 64),
  }
}

///|
/// Read a block switch: which type, and how long until the next one.
///
/// The type is coded as "the one before last", "the last", or an explicit index,
/// with explicit ones cycling modulo the count. Two recent types plus a modulo
/// ring is enough because block types almost always come in runs.
fn Frame::switch_block(
  self : Frame,
  kind : Int32,
  bits : Bits,
) -> Unit raise @moonzip.Refused {
  let count = self.blocks[kind]
  if count <= 1 {
    raise @moonzip.Header(
      at=bits.at(),
      what="a block switch in a stream of one block",
    )
  }
  let symbol = self.types[kind].read(bits)
  let code = self.sizes[kind].read(bits)
  self.length[kind] = block_len_offset[code] + bits.take(block_len_bits[code])
  let pair = kind * 2
  let mut block = symbol
  if block == 1 {
    block = self.recent[pair + 1] + 1
  } else if block == 0 {
    block = self.recent[pair]
  } else {
    block -= 2
  }
  if block >= count {
    block -= count
  }
  self.recent[pair] = self.recent[pair + 1]
  self.recent[pair + 1] = block
}

///|
/// A byte count in 0..255: one bit for "zero", three bits for a small value, then
/// that many bits of the rest. Used for the number of block types and codes.
fn read_count(bits : Bits) -> Int32 raise @moonzip.Refused {
  if bits.take(1) == 0 {
    return 0
  }
  let width = bits.take(3)
  if width == 0 {
    return 1
  }
  (1 << width) + bits.take(width)
}

///|
/// A context map: which code each of up to 256x64 contexts uses.
///
/// Almost always the answer is "the same one everywhere", which costs one bit.
/// When it is not, the map is a prefix-coded vector with a run-length escape for
/// the zeros (they dominate) and an optional move-to-front pass that turns
/// locally repeated codes into repeated small numbers.
fn read_context_map(
  bits : Bits,
  size : Int32,
) -> (Int32, FixedArray[Int32]) raise @moonzip.Refused {
  let trees = read_count(bits) + 1
  let map = FixedArray::make(size, 0)
  if trees <= 1 {
    return (trees, map)
  }
  let mut run_prefix = 0
  if bits.take(1) == 1 {
    run_prefix = bits.take(4) + 1
  }
  let code = read_prefix(bits, trees + run_prefix, trees + run_prefix)
  let mut index = 0
  while index < size {
    let symbol = code.read(bits)
    if symbol == 0 {
      map[index] = 0
      index += 1
    } else if symbol > run_prefix {
      map[index] = symbol - run_prefix
      index += 1
    } else {
      let reps = bits.take(symbol) + (1 << symbol)
      if index + reps > size {
        raise @moonzip.Header(
          at=bits.at(),
          what="a run past the end of a context map",
        )
      }
      for k in 0..<reps {
        map[index + k] = 0
      }
      index += reps
    }
  }
  if bits.take(1) == 1 {
    inverse_move_to_front(map)
  }
  (trees, map)
}

///|
fn inverse_move_to_front(map : FixedArray[Int32]) -> Unit {
  let order : Array[Int32] = []
  for i in 0..<256 {
    order.push(i)
  }
  for i in 0..<map.length() {
    let at = map[i]
    if at >= order.length() {
      break
    }
    let value = order[at]
    let mut k = at
    while k > 0 {
      order[k] = order[k - 1]
      k -= 1
    }
    order[0] = value
    map[i] = value
  }
}

///|
/// The stream-level state: the cursor, the output so far, and the four-deep
/// distance history that short distance codes refer to.
priv struct Dec {
  bits : Bits
  out : Array[Byte]
  limit : Int32
  mut max_backward : Int32
  /// Four distances in a ring, starting at 16, 15, 11, 4 so that the first short
  /// code refers to something.
  recent : FixedArray[Int32]
  mut last : Int32
  /// Bytes still to produce in the current meta-block.
  mut remaining : Int32
}

///|
fn Dec::new(data : BytesView, limit : Int32) -> Dec {
  {
    bits: Bits::new(data),
    out: [],
    limit,
    max_backward: 0,
    recent: [16, 15, 11, 4],
    last: 0,
    remaining: 0,
  }
}

///|
fn Dec::push(self : Dec, byte : Byte) -> Unit raise @moonzip.Refused {
  if self.out.length() >= self.limit {
    raise @moonzip.TooBig(limit=self.limit)
  }
  self.out.push(byte)
}

///|
/// The stream header: two to eight bits that say how far back a copy may reach.
///
/// The window is the power of two minus a slack of 16: a 16-bit window lets a
/// copy reach 65,520 bytes, not 65,536, because the encoder is allowed to look 16
/// bytes ahead while writing.
fn Dec::header(self : Dec) -> Unit raise @moonzip.Refused {
  let bits = self.bits
  let mut size = 16
  if bits.take(1) == 1 {
    let wide = bits.take(3)
    if wide != 0 {
      size = 17 + wide
    } else {
      let narrow = bits.take(3)
      if narrow == 1 {
        raise @moonzip.Header(at=bits.at(), what="the large-window extension")
      } else if narrow != 0 {
        size = 8 + narrow
      } else {
        size = 17
      }
    }
  }
  self.max_backward = (1 << size) - 16
}

///|
/// One meta-block. Returns false when the stream says it is done.
fn Dec::metablock(self : Dec) -> Bool raise @moonzip.Refused {
  let bits = self.bits
  let last = bits.take(1) == 1
  if last && bits.take(1) == 1 {
    return false
  }
  let nibbles = bits.take(2)
  let width = nibbles + 4
  let mut length = 0
  let metadata = nibbles == 3
  for i in 0..<width {
    let nibble = bits.take(4)
    if i + 1 == width && width > 4 && nibble == 0 {
      raise @moonzip.Header(
        at=bits.at(),
        what="a meta-block length with a padded nibble",
      )
    }
    length = length | (nibble << (i * 4))
  }
  if metadata {
    if bits.take(1) != 0 {
      raise @moonzip.Header(at=bits.at(), what="a reserved metadata bit")
    }
    let bytes = bits.take(2)
    let mut count = 0
    if bytes != 0 {
      for i in 0..<bytes {
        let byte = bits.take(8)
        if i + 1 == bytes && bytes > 1 && byte == 0 {
          raise @moonzip.Header(
            at=bits.at(),
            what="a metadata length with a padded byte",
          )
        }
        count = count | (byte << (i * 8))
      }
      count += 1
    }
    bits.align()
    for _ in 0..<count {
      let _ = bits.take(8)
    }
    self.remaining = 0
    return !last
  }
  length += 1
  if !last && bits.take(1) == 1 {
    bits.align()
    let raw = bits.bytes(length)
    for i in 0..<length {
      self.push(raw[i])
    }
    self.remaining = 0
    return true
  }
  self.remaining = length
  self.compressed()
  !last
}

///|
fn Dec::compressed(self : Dec) -> Unit raise @moonzip.Refused {
  let bits = self.bits
  let frame = Frame::new()
  for kind in 0..<3 {
    let count = read_count(bits) + 1
    frame.blocks[kind] = count
    if count >= 2 {
      frame.types.push(read_prefix(bits, count + 2, count + 2))
      frame.sizes.push(read_prefix(bits, 26, 26))
      let code = frame.sizes[kind].read(bits)
      frame.length[kind] = block_len_offset[code] +
        bits.take(block_len_bits[code])
    } else {
      // A stream with one block type still indexes these two per stream, so the
      // slots have to exist even though nothing reaches them.
      frame.types.push(Code::one(0))
      frame.sizes.push(Code::one(0))
    }
  }
  let shared = bits.take(6)
  let npostfix = shared & 3
  let ndirect = shared >> 2 << npostfix
  let alphabet = 16 + ndirect + (48 << npostfix)
  frame.distance_codes = distances(npostfix, ndirect, alphabet)
  let literal_blocks = frame.blocks[0]
  frame.modes = FixedArray::make(literal_blocks, 0)
  for i in 0..<literal_blocks {
    frame.modes[i] = bits.take(2)
  }
  let (literal_trees, map) = read_context_map(bits, literal_blocks << 6)
  frame.context = map
  frame.flat = FixedArray::make(literal_blocks, false)
  for block in 0..<literal_blocks {
    let base = block << 6
    let mut flat = true
    for c in 1..<64 {
      if map[base + c] != map[base] {
        flat = false
        break
      }
    }
    frame.flat[block] = flat
  }
  let (distance_trees, dmap) = read_context_map(bits, frame.blocks[2] << 2)
  frame.distance_context = dmap
  for _ in 0..<literal_trees {
    frame.literals.push(read_prefix(bits, 256, 256))
  }
  for _ in 0..<frame.blocks[1] {
    frame.commands.push(read_prefix(bits, 704, 704))
  }
  for _ in 0..<distance_trees {
    frame.distances.push(read_prefix(bits, alphabet, alphabet))
  }
  self.commands(frame)
  if self.remaining < 0 {
    raise @moonzip.Header(
      at=bits.at(),
      what="a meta-block that produced too much",
    )
  }
}

///|
/// The command loop: the whole body of a compressed meta-block.
///
/// Each command inserts some literals and then copies some bytes from earlier in
/// the output, possibly reaching into the static dictionary instead. The loop ends
/// when the meta-block's length is used up — the last command's copy is never
/// performed, which is how a stream whose tail is all literals says so.
fn Dec::commands(self : Dec, frame : Frame) -> Unit raise @moonzip.Refused {
  let bits = self.bits
  while self.remaining > 0 {
    if frame.length[1] == 0 {
      frame.switch_block(1, bits)
    }
    let cmd = cmd_lut[frame.commands[frame.recent[3]].read(bits)]
    let mut insert = cmd.insert + bits.take(cmd.insert_bits)
    let copy = cmd.copy + bits.take(cmd.copy_bits)
    frame.length[1] -= 1
    self.remaining -= insert
    while insert > 0 {
      if frame.length[0] == 0 {
        frame.switch_block(0, bits)
      }
      let block = frame.recent[1]
      let literal = if frame.flat[block] {
        frame.literals[frame.context[block << 6]].read(bits)
      } else {
        let size = self.out.length()
        let previous = if size > 0 { self.out[size - 1].to_int() } else { 0 }
        let before = if size > 1 { self.out[size - 2].to_int() } else { 0 }
        let slot = context_id(frame.modes[block], previous, before)
        frame.literals[frame.context[(block << 6) + slot]].read(bits)
      }
      frame.length[0] -= 1
      self.push(literal.to_byte())
      insert -= 1
    }
    if self.remaining <= 0 {
      return
    }
    let mut distance = 0
    let mut rewind = 0
    if cmd.distance >= 0 {
      self.last -= 1
      distance = self.recent[self.last & 3]
      rewind = if cmd.distance == 0 { 1 } else { 0 }
    } else {
      if frame.length[2] == 0 {
        frame.switch_block(2, bits)
      }
      let slot = (frame.recent[5] << 2) + cmd.context
      let symbol = frame.distances[frame.distance_context[slot]].read(bits)
      frame.length[2] -= 1
      if symbol < 16 {
        distance = self.short_distance(symbol)
        rewind = if symbol == 0 { 1 } else { 0 }
      } else {
        let codes = frame.distance_codes
        distance = codes.offset[symbol] +
          (bits.take(codes.extra[symbol]) << codes.npostfix)
      }
    }
    self.copy(distance, copy, rewind)
  }
}

///|
/// The sixteen short distance codes: the last distance, the one before it, and
/// offsets of -3..3 and -3..3 around those.
///
/// Six nibbles packed into one constant, three bits of sign each.
fn Dec::short_distance(self : Dec, symbol : Int32) -> Int32 {
  if symbol <= 3 {
    let distance = self.recent[(self.last - (symbol - 3)) & 3]
    if symbol == 0 {
      self.last -= 1
    }
    return distance
  }
  let mut index = 3
  let mut base = symbol - 10
  if symbol < 10 {
    base = symbol - 4
  } else {
    index = 2
  }
  let distance = self.recent[(self.last + index) & 3] +
    ((0x605142 >> (4 * base)) & 0xF) -
    3
  if distance <= 0 {
    0x7FFFFFFF
  } else {
    distance
  }
}

///|
/// A back-reference, or a dictionary word when the distance reaches past the
/// start of the window.
///
/// `rewind` is how much of a distance-ring roll the command undid to say "the
/// last distance": a real copy puts it back, a dictionary reference keeps it
/// undone, because a dictionary word is not a distance the ring should remember.
fn Dec::copy(
  self : Dec,
  distance : Int32,
  length : Int32,
  rewind : Int32,
) -> Unit raise @moonzip.Refused {
  let size = self.out.length()
  let reach = if size < self.max_backward { size } else { self.max_backward }
  if distance > reach {
    if distance > 0x7FFFFFFC {
      raise @moonzip.Distance(at=size)
    }
    if size + length + 32 > self.limit {
      raise @moonzip.TooBig(limit=self.limit)
    }
    dictionary_word(distance, reach, length, self.out)
    self.last += rewind
    self.remaining -= self.out.length() - size
    return
  }
  if distance <= 0 {
    raise @moonzip.Distance(at=size)
  }
  self.recent[self.last & 3] = distance
  self.last += 1
  for _ in 0..<length {
    let byte = self.out[self.out.length() - distance]
    self.push(byte)
  }
  self.remaining -= length
}
