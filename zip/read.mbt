// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Walk an archive from the front, one member at a time.
///
/// [`unzip`] reads the central directory at the end, which is what a file on
/// disk allows and what makes an entry addressable by name. A reader that is
/// *receiving* an archive — from a socket, from a pipe, out of a decompressor —
/// has no end to seek to, and the local headers are all it has. This is that
/// reader.
///
/// It also reads what a streaming writer writes: an entry whose checksum and
/// sizes sit in a data descriptor after its data rather than in its header.
/// That case is why this reader feeds DEFLATE until the stream says it has
/// ended instead of trusting a length in front of it.
struct Reader {
  archive : BytesView
  mut at : Int32
  mut closed : Bool
}

///|
/// A reader at the start of `archive`.
pub fn Reader::new(archive : BytesView) -> Reader {
  { archive, at: 0, closed: false, }
}

///|
/// The next member, or `None` when the members have run out.
///
/// `limit` bounds what one member may expand to, as everywhere else.
pub fn Reader::next(
  self : Reader,
  limit? : Int32,
  codecs~ : ArrayView[&Codec] = [],
  password? : String,
) -> Entry? raise @moonzip.Refused {
  if self.closed || self.at + 4 > self.archive.length() {
    return None
  }
  match read32(self.archive, self.at) {
    // The central directory is not a member: it is the index, and a reader
    // walking the front of the archive has finished when it reaches one.
    0x02014B50U | 0x06054B50U | 0x06064B50U => {
      self.closed = true
      return None
    }
    0x04034B50U => ()
    _ =>
      raise @moonzip.Header(
        at=self.at,
        what="expected a local header, and found something else",
      )
  }
  let base = self.at
  guard base + 30 <= self.archive.length() else {
    raise @moonzip.Truncated(at=base)
  }
  let flags = read16(self.archive, base + 6)
  let how = read16(self.archive, base + 8)
  let time = read16(self.archive, base + 10)
  let date = read16(self.archive, base + 12)
  let mut sum = read32(self.archive, base + 14)
  let mut packed = read32(self.archive, base + 18).to_int64()
  let mut unpacked = read32(self.archive, base + 22).to_int64()
  let name_len = read16(self.archive, base + 26)
  let extra_len = read16(self.archive, base + 28)
  let name_at = base + 30
  guard name_at + name_len + extra_len <= self.archive.length() else {
    raise @moonzip.Truncated(at=name_at)
  }
  let name = text(self.archive[name_at:name_at + name_len])
  let wide = widen(
    self.archive[name_at + name_len:name_at + name_len + extra_len],
  )
  let mut widened = false
  match wide.unpacked {
    Some(v) => {
      widened = true
      if unpacked == 0xFFFFFFFFL || unpacked == 0L {
        unpacked = v
      }
    }
    None => ()
  }
  match wide.packed {
    Some(v) => {
      widened = true
      if packed == 0xFFFFFFFFL || packed == 0L {
        packed = v
      }
    }
    None => ()
  }
  let head = name_at + name_len + extra_len
  let encrypted = (flags & 0x0001) != 0
  let descriptor = (flags & 0x0008) != 0
  let check = if descriptor {
    ((time >> 8) & 0xFF).to_byte()
  } else {
    ((sum >> 24) & 0xFFU).to_byte()
  }
  let tail = self.archive[head:]
  // Decrypting is a byte-for-byte stream cipher, so the whole tail can go
  // through at once and the decompressor decides how much of it was an entry.
  // The first twelve bytes are the encryption header, not the stream.
  let plain = if encrypted {
    match password {
      Some(secret) => zipcrypt_decrypt(tail, secret, check)[:]
      None =>
        raise @moonzip.Header(
          at=base + 6,
          what="an encrypted entry, and no password was given",
        )
    }
  } else {
    tail
  }
  let skip = if encrypted { 12 } else { 0 }
  let longer = packed > 0L || widened
  let (data, used) = if !descriptor || longer {
    // The header says how long the member is — always true without a
    // descriptor, and still true with one when the writer filled it in.
    let usable = packed.to_int() - skip
    guard usable >= 0 else { raise @moonzip.Truncated(at=head) }
    let made = unpack(plain[0:usable], how, base + 8, limit, None, check, codecs)
    (made, packed.to_int())
  } else if how == 8 {
    let reader = @deflate.Reader::new(limit?)
    let out : Array[Byte] = []
    for b in reader.push(plain) {
      out.push(b)
    }
    for b in reader.finish() {
      out.push(b)
    }
    let consumed = plain.length() - reader.rest().length()
    (Bytes::from_array(out), consumed + skip)
  } else if how == 0 {
    // A stored member says nothing about its length and there is nothing to
    // decompress, so the descriptor is found by looking for it: a candidate is
    // only accepted when the size it declares matches where it sits, which is a
    // check that four bytes of signature alone cannot give.
    match find_descriptor(self.archive, head, widened) {
      None =>
        raise @moonzip.Header(
          at=head,
          what="a stored member with no data descriptor after it",
        )
      Some(start) => {
        let made = unpack(
          plain[0:start - head - skip],
          how,
          base + 8,
          limit,
          None,
          check,
          codecs,
        )
        (made, start - head)
      }
    }
  } else {
    raise @moonzip.Header(
      at=base + 8,
      what="a member with its sizes in a descriptor, which cannot be found without decompressing it",
    )
  }
  let mut at = head + used
  if descriptor {
    let signed = at + 4 <= self.archive.length() &&
      read32(self.archive, at) == 0x08074B50U
    let body = if signed { at + 4 } else { at }
    if body + 4 <= self.archive.length() {
      sum = read32(self.archive, body)
    }
    at = body + (if widened { 20 } else { 12 })
  }
  self.at = at
  let got = @moonzip.crc32(data[:])
  guard got == sum else {
    raise @moonzip.Checksum(want=sum, got~)
  }
  Some({
    name,
    data,
    kind: kind_of(how),
    mtime: unix_time(time, date),
    comment: "",
  })
}

///|
/// Where a stored member's data ends and its descriptor begins, or `None` if no
/// descriptor fits.
///
/// The signature in front of a descriptor is optional, but a stored member
/// gives one thing to check a candidate against: the size it declares has to be
/// exactly the distance from the start of the data to the descriptor itself. A
/// byte pattern that survives that is the descriptor.
fn find_descriptor(
  archive : BytesView,
  from : Int32,
  wide : Bool,
) -> Int32? {
  let mut at = from
  let span = if wide { 20 } else { 12 }
  while at + span <= archive.length() {
    if read32(archive, at) == 0x08074B50U {
      let packed = if wide {
        read64(archive, at + 8)
      } else {
        read32(archive, at + 8).to_int64()
      }
      let unpacked = if wide {
        read64(archive, at + 16)
      } else {
        read32(archive, at + 12).to_int64()
      }
      // The stored size counts the encryption header when there is one, so it
      // is the byte count and not necessarily the member's length.
      if packed == (at - from).to_int64() && unpacked <= packed {
        return Some(at)
      }
    }
    at += 1
  }
  None
}
