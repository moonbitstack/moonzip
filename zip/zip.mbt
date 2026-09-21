// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How an entry's bytes are held in the archive.
///
/// The format calls it the compression method; the field is `kind`, which is
/// what this family calls "which variant of this enum" and is not a word
/// MoonBit reserves.
///
/// The two that are actually in use. APPNOTE.TXT names a dozen more — shrink,
/// implode, six reduce levels — and no tool has written one since the 1990s; a
/// reader that meets one refuses it rather than guessing.
pub(all) enum Kind {
  /// Not compressed. What an already-compressed member should use: running
  /// DEFLATE over a JPEG costs time and makes it bigger.
  Stored
  /// DEFLATE, which is what every archive in the wild uses for everything else.
  Deflated
  /// A method this package does not implement, by its APPNOTE.TXT number —
  /// bzip2 is 12, LZMA is 14. A [`Codec`] handles it; without one, reading such
  /// an entry is refused rather than guessed at.
  Other(Int)
} derive(Eq, Debug)

///|
/// A compression method beyond the two built in.
///
/// The mode is defined over a codec rather than over DEFLATE alone, for the same
/// reason GCM is defined over a block cipher: adding bzip2 to an archive should
/// cost a codec, not an edit to this package.
pub(open) trait Codec {
  /// The number APPNOTE.TXT §4.4.5 gives this method.
  fn id(Self) -> Int
  /// Compress.
  fn pack(Self, BytesView) -> Bytes
  /// Expand, honouring the caller's bound on the result.
  fn unpack(Self, BytesView, Int?) -> Bytes raise @moonzip.Broken
}

///|
/// The codec for a method number, if the caller supplied one.
fn pick(codecs : ArrayView[&Codec], id : Int) -> &Codec? {
  for codec in codecs {
    if codec.id() == id {
      return Some(codec)
    }
  }
  None
}

///|
pub extend Kind with Eq::{equal, not_equal}

///|
pub extend Kind with Debug::{to_repr}

///|
/// One member of an archive.
///
/// `data` is the content itself: decompressed when read, as-is when written.
/// An archive is a directory of whole files, so handing back half of one would
/// be handing back something that is not the file.
pub(all) struct Entry {
  /// The path inside the archive, with forward slashes — APPNOTE.TXT §4.4.17
  /// says so, on every platform.
  name : String
  /// The content.
  data : Bytes
  /// How it is held.
  kind : Kind
  /// Last modification, in Unix seconds. ZIP records MS-DOS date and time,
  /// which has two-second resolution and no zone, so a value read back is the
  /// one that was written rounded down to an even second.
  mtime : Int64
  /// The per-entry comment, which most archives leave empty.
  comment : String
} derive(Eq, Debug)

///|
pub extend Entry with Eq::{equal, not_equal}

///|
pub extend Entry with Debug::{to_repr}

///|
/// The compression level entries are written at, when they are deflated.
///
/// Six, which is `moonzip`'s default and zlib's, and therefore what `zip`,
/// Python's `zipfile` and every other writer produces.
pub let level : Int = 6

///|
/// An entry with only a name and its content, deflated, stamped at the epoch.
///
/// The epoch rather than the clock: a library has no clock, and an archive that
/// stamped the time would give different bytes for the same input and make a
/// build unreproducible. A caller with a real modification time passes it.
pub fn Entry::new(
  name : String,
  data : Bytes,
  kind? : Kind = Deflated,
  mtime? : Int64 = 0L,
  comment? : String = "",
) -> Entry {
  { name, data, kind, mtime, comment, }
}

///|
/// The number APPNOTE.TXT §4.4.5 gives a method.
fn number(kind : Kind) -> Int {
  match kind {
    Stored => 0
    Deflated => 8
    Other(id) => id
  }
}

///|
/// The method a number names.
fn kind_of(id : Int) -> Kind {
  match id {
    0 => Stored
    8 => Deflated
    other => Other(other)
  }
}

///|
fn le16(out : Array[Byte], value : Int) -> Unit {
  out.push((value & 0xFF).to_byte())
  out.push(((value >> 8) & 0xFF).to_byte())
}

///|
fn le32(out : Array[Byte], value : UInt) -> Unit {
  for i in 0..<4 {
    out.push(((value >> (i * 8)) & 0xFFU).to_byte())
  }
}

///|
fn read16(data : BytesView, at : Int) -> Int {
  data[at].to_int() | (data[at + 1].to_int() << 8)
}

///|
fn read32(data : BytesView, at : Int) -> UInt {
  let mut value = 0U
  for i in 0..<4 {
    value = value | (data[at + i].to_uint() << (i * 8))
  }
  value
}

///|
/// Days from the Unix epoch to a civil date, by Howard Hinnant's algorithm.
fn days_from(year : Int, month : Int, day : Int) -> Int64 {
  let y = if month <= 2 { year - 1 } else { year }
  let era = (if y >= 0 { y } else { y - 399 }) / 400
  let yoe = y - era * 400
  let m = if month > 2 { month - 3 } else { month + 9 }
  let doy = (153 * m + 2) / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era.to_int64() * 146097L + doe.to_int64() - 719468L
}

///|
/// The civil date a day count names, the same algorithm run backwards.
fn civil_from(days : Int64) -> (Int, Int, Int) {
  let z = days + 719468L
  let era = (if z >= 0L { z } else { z - 146096L }) / 146097L
  let doe = (z - era * 146097L).to_int()
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y = yoe.to_int64() + era * 400L
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = if mp < 10 { mp + 3 } else { mp - 9 }
  ((if m <= 2 { y + 1L } else { y }).to_int(), m, d)
}

///|
/// Unix seconds as the MS-DOS date and time ZIP records (APPNOTE.TXT §4.4.6).
///
/// Two-second resolution, no zone, and nothing before 1980 — which is the
/// format's own floor, so an earlier time is written as the floor rather than
/// wrapping into a date that means something else.
fn dos_time(unix : Int64) -> (Int, Int) {
  let days = if unix >= 0L { unix / 86400L } else { (unix - 86399L) / 86400L }
  let secs = (unix - days * 86400L).to_int()
  let (year, month, day) = civil_from(days)
  if year < 1980 {
    return (0, 33)
  }
  let time = ((secs / 3600) << 11) | ((secs % 3600 / 60) << 5) | (secs % 60 / 2)
  let date = ((year - 1980) << 9) | (month << 5) | day
  (time, date)
}

///|
/// The other direction.
fn unix_time(time : Int, date : Int) -> Int64 {
  let year = ((date >> 9) & 0x7F) + 1980
  let month = (date >> 5) & 0x0F
  let day = date & 0x1F
  if month < 1 || month > 12 || day < 1 || day > 31 {
    return 0L
  }
  let hour = (time >> 11) & 0x1F
  let minute = (time >> 5) & 0x3F
  let second = (time & 0x1F) * 2
  days_from(year, month, day) * 86400L +
  (hour * 3600 + minute * 60 + second).to_int64()
}

///|
/// Write an archive.
///
/// Entries are written in the order they are given, each with a local header,
/// then the central directory, then the end record — the layout APPNOTE.TXT
/// describes and the one every reader expects.
///
/// `level` reaches the compressor for the deflated entries; `Stored` ones carry
/// their bytes unchanged. An entry that deflates to no less than it started as
/// is stored instead, which is what `zip` itself does: a member should never
/// grow by being compressed.
pub fn zip(
  entries : ArrayView[Entry],
  level? : Int = level,
  codecs? : ArrayView[&Codec] = [],
) -> Bytes {
  let out : Array[Byte] = []
  let offsets : Array[Int] = []
  let stored : Array[Bytes] = []
  let kinds : Array[Kind] = []
  let sums : Array[UInt] = []
  for entry in entries {
    offsets.push(out.length())
    let sum = @moonzip.crc32(entry.data[:])
    let (packed, how) = match entry.kind {
      Stored => (entry.data, Kind::Stored)
      Deflated => {
        let made = @deflate.deflate(entry.data[:], level~)
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
    stored.push(packed)
    kinds.push(how)
    sums.push(sum)
    let name = @utf8.encode(entry.name[:])
    let (time, date) = dos_time(entry.mtime)
    le32(out, 0x04034B50U)
    // Version 2.0 is what DEFLATE needs; the flag bit says the name is UTF-8.
    le16(out, 20)
    le16(out, 0x0800)
    le16(out, number(how))
    le16(out, time)
    le16(out, date)
    le32(out, sum)
    le32(out, packed.length().reinterpret_as_uint())
    le32(out, entry.data.length().reinterpret_as_uint())
    le16(out, name.length())
    le16(out, 0)
    for b in name {
      out.push(b)
    }
    for b in packed {
      out.push(b)
    }
  }
  let directory = out.length()
  for i, entry in entries {
    let name = @utf8.encode(entry.name[:])
    let comment = @utf8.encode(entry.comment[:])
    let (time, date) = dos_time(entry.mtime)
    le32(out, 0x02014B50U)
    le16(out, 20)
    le16(out, 20)
    le16(out, 0x0800)
    le16(out, number(kinds[i]))
    le16(out, time)
    le16(out, date)
    le32(out, sums[i])
    le32(out, stored[i].length().reinterpret_as_uint())
    le32(out, entry.data.length().reinterpret_as_uint())
    le16(out, name.length())
    le16(out, 0)
    le16(out, comment.length())
    le16(out, 0)
    le16(out, 0)
    le32(out, 0U)
    le32(out, offsets[i].reinterpret_as_uint())
    for b in name {
      out.push(b)
    }
    for b in comment {
      out.push(b)
    }
  }
  let size = out.length() - directory
  le32(out, 0x06054B50U)
  le16(out, 0)
  le16(out, 0)
  le16(out, entries.length())
  le16(out, entries.length())
  le32(out, size.reinterpret_as_uint())
  le32(out, directory.reinterpret_as_uint())
  le16(out, 0)
  Bytes::from_array(out)
}

///|
/// Where the end-of-central-directory record begins.
///
/// It is at the end, but an archive may carry a comment after it, so the search
/// runs backwards over the 64 KiB a comment's two-byte length can reach. A
/// reader that only looks at the last 22 bytes fails on every archive with a
/// comment.
fn end_record(archive : BytesView) -> Int raise @moonzip.Broken {
  let least = 22
  guard archive.length() >= least else {
    raise @moonzip.Header(at=0, what="shorter than a zip end record")
  }
  let floor = if archive.length() > least + 65535 {
    archive.length() - least - 65535
  } else {
    0
  }
  for at = archive.length() - least; at >= floor; at = at - 1 {
    if read32(archive, at) == 0x06054B50U {
      return at
    }
  }
  raise @moonzip.Header(
    at=archive.length(),
    what="no end-of-central-directory record",
  )
}

///|
/// One entry's metadata, as the central directory records it.
priv struct Listed {
  name : String
  how : Int
  sum : UInt
  packed : Int
  mtime : Int64
  comment : String
  at : Int
}

///|
/// Walk the central directory.
fn directory(archive : BytesView) -> Array[Listed] raise @moonzip.Broken {
  let end = end_record(archive)
  let count = read16(archive, end + 10)
  let start = read32(archive, end + 16).reinterpret_as_int()
  guard start >= 0 && start <= archive.length() else {
    raise @moonzip.Header(
      at=end + 16,
      what="a central directory outside the archive",
    )
  }
  let out : Array[Listed] = []
  let mut at = start
  for _ in 0..<count {
    guard at + 46 <= archive.length() && read32(archive, at) == 0x02014B50U else {
      raise @moonzip.Header(
        at~,
        what="a central directory entry without its signature",
      )
    }
    let name_len = read16(archive, at + 28)
    let extra_len = read16(archive, at + 30)
    let comment_len = read16(archive, at + 32)
    let head = at + 46
    guard head + name_len + extra_len + comment_len <= archive.length() else {
      raise @moonzip.Truncated(at~)
    }
    out.push({
      name: text(archive[head:head + name_len]),
      how: read16(archive, at + 10),
      sum: read32(archive, at + 16),
      packed: read32(archive, at + 20).reinterpret_as_int(),
      mtime: unix_time(read16(archive, at + 12), read16(archive, at + 14)),
      comment: text(
        archive[head + name_len + extra_len:head +
        name_len +
        extra_len +
        comment_len],
      ),
      at: read32(archive, at + 42).reinterpret_as_int(),
    })
    at = head + name_len + extra_len + comment_len
  }
  out
}

///|
/// A name or a comment as text. A name that is not UTF-8 is read as Latin-1,
/// which is what the format said before the UTF-8 flag existed and what every
/// reader falls back to.
fn text(raw : BytesView) -> String {
  @utf8.decode(raw) catch {
    _ => {
      let out = StringBuilder()
      for b in raw {
        out.write_char(b.to_int().unsafe_to_char())
      }
      out.to_string()
    }
  }
}

///|
/// The content one listed entry names.
fn content(
  archive : BytesView,
  listed : Listed,
  limit : Int?,
  codecs : ArrayView[&Codec],
) -> Bytes raise @moonzip.Broken {
  let at = listed.at
  guard at >= 0 &&
    at + 30 <= archive.length() &&
    read32(archive, at) == 0x04034B50U else {
    raise @moonzip.Header(at~, what="an entry without a local header")
  }
  let name_len = read16(archive, at + 26)
  let extra_len = read16(archive, at + 28)
  let start = at + 30 + name_len + extra_len
  guard start + listed.packed <= archive.length() else {
    raise @moonzip.Truncated(at=start)
  }
  let packed = archive[start:start + listed.packed]
  let data = match listed.how {
    0 => packed.to_owned()
    8 => @deflate.inflate(packed, limit?)
    other =>
      match pick(codecs, other) {
        Some(codec) => codec.unpack(packed, limit)
        None =>
          raise @moonzip.Header(
            at=at + 8,
            what="compression method \{other}, and no codec was supplied for it",
          )
      }
  }
  guard @moonzip.crc32(data[:]) == listed.sum else {
    raise @moonzip.Checksum(want=listed.sum, got=@moonzip.crc32(data[:]))
  }
  data
}

///|
/// Every entry's name, without decompressing anything.
///
/// The central directory is a table at the end of the archive that names every
/// member; reading it costs nothing next to expanding them. This is what a
/// caller listing an archive wants, and what `zipfile.namelist()` is.
pub fn names(archive : BytesView) -> Array[String] raise @moonzip.Broken {
  directory(archive).map(listed => listed.name)
}

///|
/// One entry by name, expanding only that one.
///
/// `None` for a name the archive does not hold — asking whether something is in
/// an archive is a question, not a failure. A name that is there but whose
/// content is damaged still raises: that is a broken archive, not an absent
/// member.
pub fn entry(
  archive : BytesView,
  name : String,
  limit? : Int,
  codecs? : ArrayView[&Codec] = [],
) -> Entry? raise @moonzip.Broken {
  for listed in directory(archive) {
    if listed.name == name {
      return Some({
        name: listed.name,
        data: content(archive, listed, limit, codecs),
        kind: kind_of(listed.how),
        mtime: listed.mtime,
        comment: listed.comment,
      })
    }
  }
  None
}

///|
/// Every entry, expanded.
///
/// `limit` bounds what one entry may expand to. An archive is worth bounding
/// even more than a single stream is: a few kilobytes of archive can declare a
/// hundred members that each claim to be a gigabyte.
pub fn unzip(
  archive : BytesView,
  limit? : Int,
  codecs? : ArrayView[&Codec] = [],
) -> Array[Entry] raise @moonzip.Broken {
  let out : Array[Entry] = []
  for listed in directory(archive) {
    out.push({
      name: listed.name,
      data: content(archive, listed, limit, codecs),
      kind: kind_of(listed.how),
      mtime: listed.mtime,
      comment: listed.comment,
    })
  }
  out
}
