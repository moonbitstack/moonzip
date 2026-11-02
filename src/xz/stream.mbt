// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// An xz writer that takes the body a piece at a time.
///
/// The container is built for this: a block holds a run of LZMA2 chunks, each
/// with its own range coder and its own sizes, so a chunk can be handed over as
/// soon as it fills. What is held between calls is one chunk — a megabyte — and
/// the two counters the index and the check need. The index is written at the end
/// because that is where the format puts it, and because its sizes are only known
/// then.
///
/// ```moonbit nocheck
/// let w = @xz.Writer::new(level=6)
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
  check : Check
  /// The chunk being filled, at most the format's chunk size.
  mut held : Array[Byte]
  /// Bytes of block data written: the chunk headers, their payloads and the end
  /// mark, but not the padding — the index counts the others and not that.
  mut data_size : Int64
  /// How much has been taken in, for the index's second field.
  mut size : Int64
  crc32 : @moonzip.Crc
  crc64 : Crc64
  /// The stream header and the block header, handed out with the first chunk.
  mut header : Array[Byte]
  mut header_size : Int64
  mut closed : Bool
  mut started : Bool
}

///|
pub fn Writer::new(level~ : Int32 = 6, check~ : Check = Crc64) -> Writer {
  guard level >= 0 && level <= 9 else {
    abort("xz: level \{level} is not between 0 and 9")
  }
  let out : Array[Byte] = []
  for b in [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00] {
    out.push(b.to_byte())
  }
  let flags = Bytes::from_array([b'\x00', flag_of(check).to_byte()])
  for b in flags {
    out.push(b)
  }
  for b in check_of(flags[:], Crc32) {
    out.push(b)
  }
  {
    level,
    dict: @lzma.dictionary_for(level),
    check,
    held: [],
    data_size: 0L,
    size: 0L,
    crc32: @moonzip.Crc::new(),
    crc64: Crc64::new(),
    header: out,
    header_size: 0L,
    closed: false,
    started: false,
  }
}

///|
/// The block header: which filter, and the dictionary it needs. Padded to a
/// four-byte boundary and stamped with its own CRC, which is how the format makes
/// a header that a reader can trust before it has decoded anything.
fn Writer::block_header(self : Writer) -> Array[Byte] {
  let header : Array[Byte] = [0, 0]
  put_varint(header, 0x21L)
  put_varint(header, 1L)
  header.push(@lzma.dict_code(self.dict).to_byte())
  while (header.length() + 4) % 4 != 0 {
    header.push(0)
  }
  header[0] = (header.length() / 4).to_byte()
  let bytes = Bytes::from_array(header)
  let crc = @moonzip.crc32(bytes[:])
  for i in 0..<4 {
    header.push(((crc >> (i * 8)) & 0xFFU).to_byte())
  }
  header
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
/// Take one chunk: its range-coded bytes, or the bytes themselves when coding did
/// not pay.
fn Writer::chunk(self : Writer, out : Array[Byte]) -> Unit {
  let part = Bytes::from_array(self.held)
  self.held = []
  let packed = @lzma.encode(
    part[:],
    @lzma.properties_of(3, 0, 2),
    self.dict,
    level=self.level,
  )
  let props = @lzma.properties_of(3, 0, 2)
  let unpacked = part.length() - 1
  out.push(
    ((if self.started { 0xC0 } else { 0xE0 }) | (unpacked >> 16)).to_byte(),
  )
  out.push(((unpacked >> 8) & 0xFF).to_byte())
  out.push((unpacked & 0xFF).to_byte())
  let packed_size = packed.length() - 1
  out.push(((packed_size >> 8) & 0xFF).to_byte())
  out.push((packed_size & 0xFF).to_byte())
  out.push(props.to_byte())
  for b in packed {
    out.push(b)
  }
  self.data_size += 6L + packed.length().to_int64()
  self.started = true
  match self.check {
    None => ()
    Crc32 => self.crc32.push(part[:])
    Crc64 => self.crc64.push(part[:])
  }
}

///|
pub fn Writer::push(self : Writer, data : BytesView) -> Bytes {
  if self.closed {
    abort("xz: the writer is finished")
  }
  self.size += data.length().to_int64()
  let out : Array[Byte] = []
  if data.length() > 0 && self.header_size == 0L {
    let block = self.block_header()
    self.header_size = block.length().to_int64()
    for b in block {
      self.header.push(b)
    }
  }
  let mut at = 0
  while at < data.length() {
    let room = @lzma.chunk_size - self.held.length()
    let take = if data.length() - at < room { data.length() - at } else { room }
    for i in at..<(at + take) {
      self.held.push(data[i])
    }
    at += take
    if self.held.length() == @lzma.chunk_size {
      self.chunk(out)
    }
  }
  self.emit(out)
}

///|
pub fn Writer::finish(self : Writer) -> Bytes {
  if self.closed {
    return b""
  }
  self.closed = true
  let out : Array[Byte] = []
  let mut unpadded = 0L
  let mut blocks = 0L
  if self.size > 0L || self.held.length() > 0 {
    if self.held.length() > 0 {
      self.chunk(out)
    }
    out.push(b'\x00')
    self.data_size += 1L
    // Padding belongs between the data and the check, and the index does not
    // count it: the record says how much the block holds, not how it is aligned.
    let here = (12L + self.data_size).to_int() % 4
    for _ in 0..<((4 - here) % 4) {
      out.push(0)
    }
    match self.check {
      None => ()
      Crc32 => {
        let sum = self.crc32.finish()
        for i in 0..<4 {
          out.push(((sum >> (i * 8)) & 0xFFU).to_byte())
        }
      }
      Crc64 => {
        let mut sum = self.crc64.finish()
        for _ in 0..<8 {
          out.push((sum & 0xFFUL).to_int().to_byte())
          sum = sum / 256UL
        }
      }
    }
    unpadded = self.header_size +
      self.data_size +
      size_of(flag_of(self.check)).to_int64()
    blocks = 1L
  }
  let index : Array[Byte] = [0x00]
  put_varint(index, blocks)
  if blocks > 0L {
    put_varint(index, unpadded)
    put_varint(index, self.size)
  }
  while (index.length() + 4) % 4 != 0 {
    index.push(0)
  }
  let index_crc = crc_of_array(index)
  for i in 0..<4 {
    index.push(((index_crc >> (i * 8)) & 0xFFU).to_byte())
  }
  let index_size = index.length()
  for b in index {
    out.push(b)
  }
  let tail : Array[Byte] = []
  let words = index_size / 4 - 1
  for i in 0..<4 {
    tail.push(((words >> (i * 8)) & 0xFF).to_byte())
  }
  for b in [b'\x00', flag_of(self.check).to_byte()] {
    tail.push(b)
  }
  let tail_crc = crc_of_array(tail)
  for i in 0..<4 {
    out.push(((tail_crc >> (i * 8)) & 0xFFU).to_byte())
  }
  for b in tail {
    out.push(b)
  }
  out.push(b'Y')
  out.push(b'Z')
  self.emit(out)
}

///|
/// A reader that is fed an xz stream a piece at a time.
///
/// A chunk states both sizes, so the reader waits for exactly the bytes it needs
/// and decodes one chunk at a time; the dictionary it keeps is the one the block
/// header named. The index and the footer are checked at the end, which is the
/// only place a truncated file can be told from a whole one.
struct Reader {
  limit : Int32
  decoder : @lzma.Decoder
  /// Bytes received and not yet consumed.
  mut pending : Array[Byte]
  /// The whole stream's check type, from the header.
  mut check : Int32
  /// The block being read, and the dictionary it named.
  mut dict : Int32
  /// The running check over the block's bytes.
  mut crc32 : @moonzip.Crc
  mut crc64 : Crc64
  /// How many bytes of the stream have been consumed, which is what the block's
  /// padding is measured from.
  mut position : Int64
  /// How many bytes the index took, which the footer repeats.
  mut index_size : Int32
  /// How much has come out, for `limit`.
  mut total : Int32
  /// Zero at the stream header, one at a block header, two in a block's chunks,
  /// three at its padding and check, four at the index and footer.
  mut stage : Int32
}

///|
pub fn Reader::new(limit? : Int32) -> Reader {
  {
    limit: match limit {
      Some(n) => n
      None => -1
    },
    decoder: @lzma.Decoder::new(limit?),
    pending: [],
    check: 4,
    dict: 1 << 23,
    crc32: @moonzip.Crc::new(),
    crc64: Crc64::new(),
    position: 0L,
    index_size: 0,
    total: 0,
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
  self.position += used.to_int64()
}

///|
pub fn Reader::push(
  self : Reader,
  data : BytesView,
) -> Bytes raise @moonzip.Refused {
  for b in data {
    self.pending.push(b)
  }
  let out : Array[Byte] = []
  let mut used = 0
  while true {
    let view = Bytes::from_array(self.pending)[:]
    let left = view.length() - used
    if self.stage == 0 {
      if left < 12 {
        break
      }
      for i in 0..<6 {
        if view[used + i] != [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00][i].to_byte() {
          raise @moonzip.Header(at=used, what="not an xz stream")
        }
      }
      let want = read32(view, used + 8)
      let got = @moonzip.crc32(view[used + 6:used + 8])
      if got != want {
        raise @moonzip.Checksum(want~, got~)
      }
      self.check = view[used + 7].to_int() & 0x0F
      used += 12
      self.stage = 1
      continue
    }
    if self.stage == 1 {
      if left < 2 {
        break
      }
      if view[used] == b'\x00' {
        self.stage = 4
        continue
      }
      let header_size = (view[used].to_int() + 1) * 4
      if left < header_size {
        break
      }
      let header = view[used:used + header_size]
      let want = read32(header, header_size - 4)
      let got = @moonzip.crc32(header[0:header_size - 4])
      if got != want {
        raise @moonzip.Checksum(want~, got~)
      }
      let block_flags = header[1].to_int()
      if (block_flags & 0x03) != 0 {
        raise @moonzip.Header(at=used, what="a block with more than one filter")
      }
      let mut cursor = 2
      let filter = match get_varint(header, cursor) {
        Some(pair) => {
          cursor = pair.1
          pair.0
        }
        None => raise @moonzip.Truncated(at=used)
      }
      if filter != 0x21L {
        raise @moonzip.Header(
          at=used,
          what="a filter that is not LZMA2, and no other filter is implemented",
        )
      }
      let _ = match get_varint(header, cursor) {
        Some(pair) => cursor = pair.1
        None => raise @moonzip.Truncated(at=used)
      }
      if cursor < header_size - 4 {
        self.dict = @lzma.decoded_dict(header[cursor].to_int())
        cursor += 1
      } else {
        self.dict = 1 << 23
      }
      let _ = cursor
      self.crc32 = @moonzip.Crc::new()
      self.crc64 = Crc64::new()
      used += header_size
      self.stage = 2
      continue
    }
    if self.stage == 2 {
      if left < 1 {
        break
      }
      let control = view[used].to_int()
      if control == 0 {
        used += 1
        self.stage = 3
        continue
      }
      if control == 1 || control == 2 {
        if left < 3 {
          break
        }
        let size = ((view[used + 1].to_int() << 8) | view[used + 2].to_int()) +
          1
        if left < 3 + size {
          break
        }
        let body = view[used + 3:used + 3 + size]
        if control == 1 {
          self.decoder.reset()
        }
        self.decoder.append(body)
        let made = body.to_owned()
        self.sum(made[:])
        for b in made {
          out.push(b)
        }
        used += 3 + size
        self.decoder.trim(self.dict)
        continue
      }
      if control < 0x80 {
        raise @moonzip.Header(
          at=used,
          what="an LZMA2 chunk header the format does not define",
        )
      }
      if left < 5 {
        break
      }
      let reset = (control >> 5) & 0x03
      let unpacked = (
          ((control & 0x1F) << 16) |
          (view[used + 1].to_int() << 8) |
          view[used + 2].to_int()
        ) +
        1
      let packed = ((view[used + 3].to_int() << 8) | view[used + 4].to_int()) +
        1
      let extra = if reset >= 2 { 1 } else { 0 }
      if left < 5 + extra + packed {
        break
      }
      if reset >= 2 {
        self.decoder.properties(view[used + 5].to_int())
      }
      if reset >= 1 {
        self.decoder.reset()
      }
      let at = used + 5 + extra
      let mark = self.decoder.length()
      self.decoder.feed(view[at:at + packed], unpacked) |> ignore
      let made = self.decoder.since(mark)
      if made.length() != unpacked {
        raise @moonzip.Length(
          want=unpacked.reinterpret_as_uint(),
          got=made.length(),
        )
      }
      self.sum(made[:])
      for b in made {
        out.push(b)
      }
      used = at + packed
      self.decoder.trim(self.dict)
      continue
    }
    if self.stage == 3 {
      // The block's padding is measured from the start of the block header, which
      // is why the reader counts the whole stream rather than the block.
      let here = (self.position + used.to_int64()).to_int() % 4
      if here != 0 {
        if left < 4 - here {
          break
        }
        for i in 0..<(4 - here) {
          if view[used + i] != b'\x00' {
            raise @moonzip.Header(
              at=used + i,
              what="a padding byte that is not zero",
            )
          }
        }
        used += 4 - here
        continue
      }
      let stamp = size_of(self.check)
      if left < stamp {
        break
      }
      let want = view[used:used + stamp]
      let got = match self.check {
        1 => {
          let sum = self.crc32.finish()
          let bytes : Array[Byte] = []
          for i in 0..<4 {
            bytes.push(((sum >> (i * 8)) & 0xFFU).to_byte())
          }
          Bytes::from_array(bytes)
        }
        4 => {
          let mut sum = self.crc64.finish()
          let bytes : Array[Byte] = []
          for _ in 0..<8 {
            bytes.push((sum & 0xFFUL).to_int().to_byte())
            sum = sum / 256UL
          }
          Bytes::from_array(bytes)
        }
        _ => Bytes::new(0)
      }
      if got.length() > 0 {
        for i in 0..<stamp {
          if want[i] != got[i] {
            raise @moonzip.Checksum(want=read32(want, 0), got=read32(got, 0))
          }
        }
      }
      used += stamp
      self.stage = 1
      continue
    }
    if self.stage == 4 {
      if left < 1 {
        break
      }
      // The index is a run of variable-length numbers, then padding to the
      // four-byte boundary its own CRC sits on.
      let index : Array[Byte] = []
      index.push(view[used])
      let mut cursor = 1
      let count = match get_varint(view[used + cursor:], 0) {
        Some(pair) => {
          cursor += pair.1
          pair.0
        }
        None => break
      }
      let mut ok = true
      for _ in 0..<count.to_int() {
        for _ in 0..<2 {
          match get_varint(view[used + cursor:], 0) {
            Some(pair) => cursor += pair.1
            None => ok = false
          }
        }
      }
      if !ok {
        break
      }
      while (cursor + 4) % 4 != 0 {
        cursor += 1
      }
      if left < cursor + 4 {
        break
      }
      for i in 1..<cursor {
        index.push(view[used + i])
      }
      let want = read32(view, used + cursor)
      let got = crc_of_array(index)
      if want != got {
        raise @moonzip.Checksum(want~, got~)
      }
      self.index_size = cursor + 4
      used += cursor + 4
      self.stage = 5
      continue
    }
    if self.stage == 5 {
      if left < 12 {
        break
      }
      let want = read32(view, used)
      let got = @moonzip.crc32(view[used + 4:used + 10])
      if want != got {
        raise @moonzip.Checksum(want~, got~)
      }
      if view[used + 10] != b'Y' || view[used + 11] != b'Z' {
        raise @moonzip.Header(
          at=used + 10,
          what="no stream footer, so the file is not whole",
        )
      }
      let backwards = read32(view, used + 4).reinterpret_as_int()
      if (backwards + 1) * 4 != self.index_size {
        raise @moonzip.Header(
          at=used + 4,
          what="a footer that does not point at the index",
        )
      }
      used += 12
      self.stage = 6
      continue
    }
    break
  }
  self.drop(used)
  Bytes::from_array(out)
}

///|
/// Fold a chunk's bytes into the block's check, and count them.
fn Reader::sum(self : Reader, made : BytesView) -> Unit {
  self.total += made.length()
  match self.check {
    1 => self.crc32.push(made)
    4 => self.crc64.push(made)
    _ => ()
  }
}

///|
pub fn Reader::finish(self : Reader) -> Bytes raise @moonzip.Refused {
  let tail = self.push(b"")
  if self.stage != 6 || self.pending.length() > 0 {
    raise @moonzip.Truncated(at=self.pending.length())
  }
  if self.limit >= 0 && self.total > self.limit {
    raise @moonzip.TooBig(limit=self.limit)
  }
  tail
}
