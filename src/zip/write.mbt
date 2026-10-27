// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The number the format uses for "this field did not fit in 32 bits".
let sentinel : Int64 = 0xFFFFFFFFL

// ------------------------------------------------------------ the extra field

///|
fn le64(out : Array[Byte], value : Int64) -> Unit {
  for i in 0..<8 {
    out.push(((value >> (i * 8)) & 0xFFL).to_int().to_byte())
  }
}

///|
fn read64(data : BytesView, at : Int32) -> Int64 {
  let mut value = 0L
  for i in 0..<8 {
    value = value | (data[at + i].to_uint().to_int64() << (i * 8))
  }
  value
}

///|
/// The Zip64 extended-information field (APPNOTE.TXT §4.5.3), for a local
/// header.
///
/// The two sizes are eight bytes each instead of four, and the four-byte fields
/// they replace are filled with the sentinel. A reader that does not know the
/// field sees a file of exactly 4 GiB minus one, which is why a reader that
/// does not know it should refuse rather than guess.
fn zip64_local(unpacked : Int64, packed : Int64) -> Array[Byte] {
  let out : Array[Byte] = []
  le16(out, 0x0001)
  // Two eight-byte values, and the length field counts the bytes after it —
  // which is 16, not 20. A reader that trusts the field would walk off the end
  // of the header on a length that was one word too long.
  le16(out, 16)
  le64(out, unpacked)
  le64(out, packed)
  out
}

///|
/// The same field for a central directory entry, which also carries the offset
/// of the local header.
fn zip64_central(
  unpacked : Int64,
  packed : Int64,
  offset : Int64,
) -> Array[Byte] {
  let out : Array[Byte] = []
  le16(out, 0x0001)
  le16(out, 24)
  le64(out, unpacked)
  le64(out, packed)
  le64(out, offset)
  out
}

///|
/// What a Zip64 field said, for the reader.
priv struct Widened {
  unpacked : Int64?
  packed : Int64?
  offset : Int64?
}

///|
/// Find and read the Zip64 field in an entry's extra data.
///
/// The values in it are positional and only the ones whose four-byte
/// counterpart is the sentinel are present, so the caller says which it is
/// looking for and they are taken in the order the specification lays down.
fn widen(extra : BytesView) -> Widened raise @moonzip.Refused {
  let mut at = 0
  while at + 4 <= extra.length() {
    let id = read16(extra, at)
    let len = read16(extra, at + 2)
    guard at + 4 + len <= extra.length() else {
      raise @moonzip.Header(at~, what="an extra field longer than the header")
    }
    if id == 0x0001 {
      let body = extra[at + 4:at + 4 + len]
      let mut step = 0
      let mut unpacked : Int64? = None
      let mut packed : Int64? = None
      let mut offset : Int64? = None
      for want in [0, 1, 2] {
        if step + 8 <= body.length() {
          let value = read64(body, step)
          step += 8
          match want {
            0 => unpacked = Some(value)
            1 => packed = Some(value)
            _ => offset = Some(value)
          }
        }
      }
      return { unpacked, packed, offset, }
    }
    at += 4 + len
  }
  { unpacked: None, packed: None, offset: None, }
}

// ------------------------------------------------------------------- the writer

///|
/// One entry as the central directory will remember it.
priv struct Placed {
  name : String
  comment : String
  how : Kind
  sum : UInt32
  packed : Int64
  unpacked : Int64
  mtime : Int64
  offset : Int64
  widened : Bool
}

///|
/// Build an archive a member at a time.
///
/// [`zip`] is this writer with every entry added and then finished, which is
/// the shape a caller with the whole archive in hand wants. A caller that is
/// receiving members one at a time — a backup running, a directory being
/// walked — wants this instead: `add` hands back the bytes for that member
/// immediately, and only the central directory waits for the end.
///
/// Three knobs decide the bytes beyond the content itself:
///
/// `zip64` widens the size and offset fields to sixty-four bits. It turns
/// itself on when an entry or an offset does not fit in thirty-two, which is
/// the only reason it exists; forcing it is for a caller whose reader expects
/// the wider form.
///
/// `descriptor` puts each entry's checksum and sizes after its data instead of
/// in its local header (APPNOTE.TXT §4.3.9). That is what a writer that streams
/// a member it has not finished reading must do — it cannot know the sizes when
/// it writes the header — and it costs twelve bytes a member.
///
/// `password?` encrypts each member with ZipCrypto, which is what the format
/// called encryption for fifteen years. It is not a security boundary; see
/// [`zipcrypt_encrypt`](#zipcrypt_encrypt).
struct Writer {
  level : Int32
  zip64 : Bool
  descriptor : Bool
  password : String?
  placed : Array[Placed]
  mut at : Int64
  mut closed : Bool
}

///|
/// A writer that has written nothing yet.
pub fn Writer::new(
  level~ : Int32 = level,
  zip64~ : Bool = false,
  descriptor~ : Bool = false,
  password? : String,
) -> Writer {
  { level, zip64, descriptor, password, placed: [], at: 0L, closed: false, }
}

///|
/// Add a member and take the bytes it occupies: a local header, its data, and a
/// data descriptor if one was asked for.
///
/// The compressed form is kept only if it is smaller than the input. A member
/// that grew by being compressed is stored instead, which is what `zip` itself
/// does and what makes an archive of already-compressed files the size of the
/// files.
pub fn Writer::add(
  self : Writer,
  entry : Entry,
  codecs~ : ArrayView[&Codec] = [],
) -> Bytes {
  if self.closed {
    abort("zip: the writer is finished")
  }
  let sum = @moonzip.crc32(entry.data[:])
  let (packed, how) = match entry.kind {
    Stored => (entry.data, Kind::Stored)
    Deflated => {
      let made = @deflate.deflate(entry.data[:], level=self.level)
      if made.length() < entry.data.length() {
        (made, Kind::Deflated)
      } else {
        (entry.data, Kind::Stored)
      }
    }
    Other(id) =>
      match pick(codecs, id) {
        Some(codec) => (codec.pack(entry.data[:]), Kind::Other(id))
        None => abort("zip: no codec for compression method \{id}")
      }
  }
  let (time, date) = dos_time(entry.mtime)
  // With a data descriptor the local header cannot say the checksum yet, so
  // the byte that proves a password right is taken from the time instead. That
  // is what the format says, and a reader that ignores it rejects every
  // encrypted entry a streaming writer produced.
  let check = if self.descriptor {
    ((time >> 8) & 0xFF).to_byte()
  } else {
    ((sum >> 24) & 0xFFU).to_byte()
  }
  let body = match self.password {
    Some(password) =>
      zipcrypt_encrypt(packed[:], password, entry.name, entry.mtime, check)
    None => packed
  }
  let packed_len = body.length().to_int64()
  let unpacked_len = entry.data.length().to_int64()
  let offset = self.at
  let widen = self.zip64 ||
    packed_len >= sentinel ||
    unpacked_len >= sentinel ||
    offset >= sentinel
  let name = @utf8.encode(entry.name[:])
  let mut flags = 0x0800
  if self.password is Some(_) {
    flags = flags | 0x0001
  }
  if self.descriptor {
    flags = flags | 0x0008
  }
  let extra = if widen { zip64_local(unpacked_len, packed_len) } else { [] }
  let out : Array[Byte] = []
  le32(out, 0x04034B50U)
  le16(out, if widen { 45 } else { 20 })
  le16(out, flags)
  le16(out, number(how))
  le16(out, time)
  le16(out, date)
  le32(out, if self.descriptor { 0U } else { sum })
  le32(
    out,
    if self.descriptor {
      0U
    } else if widen {
      0xFFFFFFFFU
    } else {
      packed_len.to_int().reinterpret_as_uint()
    },
  )
  le32(
    out,
    if self.descriptor {
      0U
    } else if widen {
      0xFFFFFFFFU
    } else {
      unpacked_len.to_int().reinterpret_as_uint()
    },
  )
  le16(out, name.length())
  le16(out, extra.length())
  for b in name {
    out.push(b)
  }
  for b in extra {
    out.push(b)
  }
  for b in body {
    out.push(b)
  }
  if self.descriptor {
    le32(out, 0x08074B50U)
    le32(out, sum)
    if widen {
      le64(out, packed_len)
      le64(out, unpacked_len)
    } else {
      le32(out, packed_len.to_int().reinterpret_as_uint())
      le32(out, unpacked_len.to_int().reinterpret_as_uint())
    }
  }
  self.at = self.at + out.length().to_int64()
  self.placed.push({
    name: entry.name,
    comment: entry.comment,
    how,
    sum,
    packed: packed_len,
    unpacked: unpacked_len,
    mtime: entry.mtime,
    offset,
    widened: widen,
  })
  Bytes::from_array(out)
}

///|
/// Close the archive: the central directory, then the end record — and the
/// Zip64 end record and its locator as well if any entry needed widening.
pub fn Writer::finish(self : Writer) -> Bytes {
  if self.closed {
    return b""
  }
  self.closed = true
  let out : Array[Byte] = []
  let directory = self.at
  let mut any_wide = false
  for placed in self.placed {
    if placed.widened {
      any_wide = true
    }
    let name = @utf8.encode(placed.name[:])
    let comment = @utf8.encode(placed.comment[:])
    let (time, date) = dos_time(placed.mtime)
    let extra = if placed.widened {
      zip64_central(placed.unpacked, placed.packed, placed.offset)
    } else {
      []
    }
    le32(out, 0x02014B50U)
    // "Made by" keeps the DOS host, as it always has, so the bytes of an
    // archive that needs no widening do not change; the version needed says
    // 4.5 when it does, because that is the first one that can read it.
    le16(out, 20)
    le16(out, if placed.widened { 45 } else { 20 })
    le16(
      out,
      (if self.password is Some(_) { 0x0001 } else { 0 }) |
      (if self.descriptor { 0x0008 } else { 0 }) |
      0x0800,
    )
    le16(out, number(placed.how))
    le16(out, time)
    le16(out, date)
    le32(out, placed.sum)
    le32(
      out,
      if placed.widened {
        0xFFFFFFFFU
      } else {
        placed.packed.to_int().reinterpret_as_uint()
      },
    )
    le32(
      out,
      if placed.widened {
        0xFFFFFFFFU
      } else {
        placed.unpacked.to_int().reinterpret_as_uint()
      },
    )
    le16(out, name.length())
    le16(out, extra.length())
    le16(out, comment.length())
    le16(out, 0)
    le16(out, 0)
    le32(out, 0U)
    le32(
      out,
      if placed.widened {
        0xFFFFFFFFU
      } else {
        placed.offset.to_int().reinterpret_as_uint()
      },
    )
    for b in name {
      out.push(b)
    }
    for b in extra {
      out.push(b)
    }
    for b in comment {
      out.push(b)
    }
  }
  let size = out.length().to_int64()
  let end_at = directory + size
  let count = self.placed.length().to_int64()
  if any_wide || self.zip64 {
    le32(out, 0x06064B50U)
    le64(out, 44L)
    le16(out, 45)
    le16(out, 45)
    le32(out, 0U)
    le32(out, 0U)
    le64(out, count)
    le64(out, count)
    le64(out, size)
    le64(out, directory)
    le32(out, 0x07064B50U)
    le32(out, 0U)
    le64(out, end_at)
    le32(out, 1U)
  }
  le32(out, 0x06054B50U)
  le16(out, 0)
  le16(out, 0)
  le16(out, if any_wide || self.zip64 { 0xFFFF } else { count.to_int() })
  le16(out, if any_wide || self.zip64 { 0xFFFF } else { count.to_int() })
  le32(
    out,
    if any_wide || self.zip64 {
      0xFFFFFFFFU
    } else {
      size.to_int().reinterpret_as_uint()
    },
  )
  le32(
    out,
    if any_wide || self.zip64 {
      0xFFFFFFFFU
    } else {
      directory.to_int().reinterpret_as_uint()
    },
  )
  le16(out, 0)
  Bytes::from_array(out)
}
