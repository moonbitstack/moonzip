// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What a member of an archive is.
///
/// tar carries more than files: a directory, a symbolic link, a hard link to a
/// member further up, and the three device nodes. The ones a caller is likely to
/// meet are here; the rest are kept as [`Other`](#Other) so that reading an
/// archive with a device node in it does not fail, and so that writing one back
/// out produces what came in.
pub(all) enum Tarball {
  /// A regular file. The only one with bytes in it.
  File
  /// A directory. Its name ends with a slash and its size is zero.
  Directory
  /// A symbolic link, whose target is in the entry's `link` field.
  Symlink
  /// A hard link to a member already in the archive, by the name in `link`.
  Hardlink
  /// A character or block device, a FIFO, or a type this package does not name.
  Other(Byte)
} derive(Eq, Debug)

///|
pub extend Tarball with Eq::{equal, not_equal}

///|
pub extend Tarball with Debug::{to_repr}

///|
/// One member of an archive.
pub(all) struct Entry {
  /// The path inside the archive, with forward slashes.
  name : String
  /// The content. Empty for anything that is not a file.
  data : Bytes
  /// What it is.
  kind : Tarball
  /// Permission bits, which tar keeps as a whole 07777 — setuid and sticky
  /// included, because a tar that dropped them could not restore `/usr/bin`.
  mode : Int32
  /// Last modification, in Unix seconds.
  mtime : Int64
  uid : Int32
  gid : Int32
  /// The owner's name, which is what a reader prefers over the number when the
  /// archive is restored on a different machine.
  uname : String
  /// The group's name.
  gname : String
  /// The target of a link.
  link : String
} derive(Eq, Debug)

///|
pub extend Entry with Eq::{equal, not_equal}

///|
pub extend Entry with Debug::{to_repr}

///|
/// A file with only a name and its content.
pub fn Entry::new(
  name : String,
  data : Bytes,
  kind~ : Tarball = File,
  mode~ : Int32 = 0o644,
  mtime~ : Int64 = 0L,
) -> Entry {
  {
    name,
    data,
    kind,
    mode: if kind is Directory {
      0o755
    } else {
      mode
    },
    mtime,
    uid: 0,
    gid: 0,
    uname: "",
    gname: "",
    link: "",
  }
}

///|
/// A directory entry.
pub fn Entry::directory(name : String, mode~ : Int32 = 0o755) -> Entry {
  {
    name: if name.has_suffix("/") {
      name
    } else {
      name + "/"
    },
    data: b"",
    kind: Directory,
    mode,
    mtime: 0L,
    uid: 0,
    gid: 0,
    uname: "",
    gname: "",
    link: "",
  }
}

///|
/// A symbolic link.
pub fn Entry::symlink(name : String, target : String) -> Entry {
  {
    name,
    data: b"",
    kind: Symlink,
    mode: 0o777,
    mtime: 0L,
    uid: 0,
    gid: 0,
    uname: "",
    gname: "",
    link: target,
  }
}

// ------------------------------------------------------------------- the shape

///|
/// A tar record is five hundred and twelve bytes, and everything in the format
/// is counted in them.
let block : Int32 = 512

///|
/// How long a name may be before it needs somewhere else to live.
let name_room : Int32 = 100

///|
/// The type flag each kind of member carries (POSIX / GNU tar).
fn flag_of(kind : Tarball) -> Byte {
  match kind {
    File => b'0'
    Directory => b'5'
    Symlink => b'2'
    Hardlink => b'1'
    Other(byte) => byte
  }
}

///|
fn kind_of(byte : Byte) -> Tarball {
  match byte {
    b'0' | b'\x00' => File
    b'5' => Directory
    b'2' => Symlink
    b'1' => Hardlink
    other => Other(other)
  }
}

// ------------------------------------------------------------------ the writer

///|
/// Write an archive.
///
/// Members go out in the order they are given, each as a header, its bytes
/// padded to a block boundary, then two empty blocks to say the archive is over.
///
/// A name longer than a hundred bytes is carried in a pax extended header,
/// which is a member of its own whose content is a list of `keyword=value`
/// records. That is the POSIX answer, and it is what GNU tar and bsdtar both
/// read; the older GNU `L` record is read but not written, because one way to
/// say a thing is enough.
///
/// The archive is reproducible: the modification time comes from the entry and
/// the owner is nobody, so the same entries always give the same bytes. Set
/// `mtime` and `uid` on an entry when it should carry something else.
pub fn tar(entries : ArrayView[Entry]) -> Bytes {
  let out : Array[Byte] = []
  for entry in entries {
    let mut name = entry.name
    if entry.kind is Directory && !name.has_suffix("/") {
      name = name + "/"
    }
    // A path that does not fit the hundred-byte field can sometimes be split
    // between the name and the prefix field, which is what ustar added for
    // exactly this. Only when that fails does a pax record come into it.
    let (short, prefix) = split_path(name)
    let mut pax : Array[Byte] = []
    if short is None {
      pax = pax_records([("path", name)])
    }
    if entry.link.length() > name_room {
      pax = pax + pax_records([("linkpath", entry.link)])
    }
    if pax.length() > 0 {
      write_member(
        out,
        {
          name: "PaxHeaders/moonzip",
          data: Bytes::from_array(pax),
          kind: Other(b'x'),
          mode: 0o644,
          mtime: entry.mtime,
          uid: 0,
          gid: 0,
          uname: "",
          gname: "",
          link: "",
        },
        "PaxHeaders/moonzip",
        "",
      )
    }
    let shown = match short {
      Some(text) => text
      None => truncate(name, name_room)
    }
    write_member(out, entry, shown, prefix)
  }
  for _ in 0..<2 {
    for _ in 0..<block {
      out.push(0)
    }
  }
  Bytes::from_array(out)
}

///|
/// Split a path into what fits the name field and what fits the prefix field, or
/// `None` when even that cannot hold it.
fn split_path(name : String) -> (String?, String) {
  if name.length() <= name_room {
    return (Some(name), "")
  }
  // The break has to be at a slash, and the piece before it goes in `prefix`.
  let mut at = name.length() - name_room
  while at < name.length() {
    if name.at(at) == '/' {
      let head = name[0:at].to_owned()
      let tail = name[at + 1:].to_owned()
      if head.length() <= 155 && tail.length() <= name_room {
        return (Some(tail), head)
      }
      return (None, "")
    }
    at += 1
  }
  (None, "")
}

///|
/// The first `n` bytes of a string, as a string. Only ever used on a name that
/// is going into a pax record as well, so the truncation is not the only copy.
fn truncate(text : String, n : Int32) -> String {
  if text.length() <= n {
    text
  } else {
    text[0:n].to_owned()
  }
}

///|
/// One pax extended header's payload: `LEN keyword=value\n` per record, where
/// `LEN` counts itself. The self-reference is what makes a parser read the
/// length twice, and what makes it unambiguous.
fn pax_records(pairs : Array[(String, String)]) -> Array[Byte] {
  let out : Array[Byte] = []
  for pair in pairs {
    let (key, value) = pair
    let rest = key.length() + value.length() + 3
    // The length field's own digits are part of the length, so the total is
    // found by iterating: one more digit can push the total over a boundary.
    let mut total = rest
    while true {
      let digits = "\{total}".length()
      let next = digits + rest
      if next == total {
        break
      }
      total = next
    }
    for b in "\{total} \{key}=\{value}\n" {
      out.push((b.to_int() & 0xFF).to_byte())
    }
  }
  out
}

///|
/// One header, the member's bytes, and the padding that rounds them to a block.
fn write_member(
  out : Array[Byte],
  entry : Entry,
  name : String,
  prefix : String,
) -> Unit {
  let header : Array[Byte] = Array::make(block, b'\x00')
  put_text(header, 0, name_room, name)
  put_octal(header, 100, 8, entry.mode.to_int64() & 0o7777L)
  put_octal(header, 108, 8, entry.uid.to_int64())
  put_octal(header, 116, 8, entry.gid.to_int64())
  let size = match entry.kind {
    File | Other(b'x') | Other(b'g') => entry.data.length().to_int64()
    _ => 0L
  }
  put_octal(header, 124, 12, size)
  put_octal(header, 136, 12, entry.mtime)
  // The checksum field is spaces while the checksum is taken, then written —
  // six octal digits, a NUL and a space, which is the one field the format
  // spells with a trailing blank.
  for i in 148..<156 {
    header[i] = b' '
  }
  header[156] = flag_of(entry.kind)
  put_text(header, 157, name_room, entry.link)
  put_text(header, 257, 6, "ustar")
  put_text(header, 263, 2, "00")
  put_text(header, 265, 32, entry.uname)
  put_text(header, 297, 32, entry.gname)
  put_octal(header, 329, 8, 0L)
  put_octal(header, 337, 8, 0L)
  put_text(header, 345, 155, prefix)
  let mut sum = 0L
  for b in header {
    sum += b.to_int().to_int64()
  }
  put_octal(header, 148, 7, sum)
  header[155] = b' '
  for b in header {
    out.push(b)
  }
  if size > 0L {
    for b in entry.data {
      out.push(b)
    }
  }
  let used = (size % block.to_int64()).to_int()
  let mut pad = if used == 0 { 0 } else { block - used }
  while pad > 0 {
    out.push(0)
    pad -= 1
  }
}

///|
/// A NUL-padded text field.
fn put_text(
  header : Array[Byte],
  at : Int32,
  width : Int32,
  text : String,
) -> Unit {
  let mut i = 0
  while i < width && i < text.length() {
    header[at + i] = (text.at(i).to_int() & 0xFF).to_byte()
    i += 1
  }
}

///|
/// An octal field of `width` bytes: `width - 1` digits and a NUL. A value that
/// does not fit goes in base 256 instead, which is what GNU tar does and what
/// every reader in use accepts.
fn put_octal(
  header : Array[Byte],
  at : Int32,
  width : Int32,
  value : Int64,
) -> Unit {
  let digits = width - 1
  let ceiling = 1L << (digits * 3)
  if value < 0L || value >= ceiling {
    // Base 256, written from the least significant byte backwards: a shift by a
    // variable amount on a sixty-four-bit value is not something this language
    // makes cheap, and dividing by 256 is the same thing.
    let mut left = value
    for i in 0..<width {
      header[at + width - 1 - i] = (left & 0xFFL).to_int().to_byte()
      left = left / 256L
    }
    header[at] = (header[at].to_int() | 0x80).to_byte()
    return
  }
  let mut left = value
  for i in 0..<digits {
    let slot = at + digits - 1 - i
    header[slot] = ((left & 7L).to_int() + 48).to_byte()
    left = left >> 3
  }
  header[at + digits] = b'\x00'
}

// ------------------------------------------------------------------ the reader

///|
/// Read an archive.
///
/// Both ustar and pax come out, and the GNU long-name records that older
/// archives use are understood on the way. `limit` bounds what one member may
/// expand to, and tar needs it more than most: an archive is a header claiming a
/// length, and a header can claim anything.
pub fn untar(
  archive : BytesView,
  limit? : Int32,
) -> Array[Entry] raise @moonzip.Refused {
  scan(
    archive,
    match limit {
      Some(n) => n
      None => -1
    },
    true,
  )
}

///|
/// The walk both readers share.
///
/// `bodies` off is what a listing wants: the headers are read and the content
/// stepped over, so naming the members of an archive with a gigabyte in it costs
/// nothing but the headers themselves.
fn scan(
  archive : BytesView,
  bound : Int32,
  bodies : Bool,
) -> Array[Entry] raise @moonzip.Refused {
  let out : Array[Entry] = []
  let mut at = 0
  // pax records apply to the next member and no further, so they are gathered
  // as they are seen and cleared when a member is finished.
  let mut over_path : String? = None
  let mut over_link : String? = None
  let mut over_mtime : Int64? = None
  let mut over_size : Int64? = None
  let mut gnu_name : String? = None
  while at + block <= archive.length() {
    if is_zero(archive, at) {
      break
    }
    let header = archive[at:at + block]
    let size = read_octal(header, 124, 12)
    let flag = header[156]
    let body_at = at + block
    let body_len = if size > 0L { size.to_int() } else { 0 }
    guard body_at + body_len <= archive.length() else {
      raise @moonzip.Truncated(at=body_at)
    }
    if bound >= 0 && body_len > bound {
      raise @moonzip.TooBig(limit=bound)
    }
    let body = archive[body_at:body_at + body_len]
    let padded = (block - body_len % block) % block
    at = body_at + body_len + padded
    match flag {
      // A pax extended header is a member that describes the next member.
      b'x' => {
        for pair in pax_records_of(body) {
          let (key, value) = pair
          match key {
            "path" => over_path = Some(value)
            "linkpath" => over_link = Some(value)
            "mtime" => over_mtime = decimal(value)
            "size" => over_size = decimal(value)
            _ => ()
          }
        }
        continue
      }
      b'g' => continue
      // The GNU long-name record: a member whose whole body is the name.
      b'L' => {
        gnu_name = Some(text_of(body))
        continue
      }
      b'K' => continue
      _ => ()
    }
    let mut name = match gnu_name {
      Some(wide) => wide
      None => {
        let short = text_of(header[0:name_room])
        let prefix = text_of(header[345:345 + 155])
        if prefix.length() > 0 {
          prefix + "/" + short
        } else {
          short
        }
      }
    }
    match over_path {
      Some(wide) => name = wide
      None => ()
    }
    let link = match over_link {
      Some(wide) => wide
      None => text_of(header[157:157 + name_room])
    }
    let expected = match over_size {
      Some(wide) => wide.to_int()
      None => body_len
    }
    let mtime = match over_mtime {
      Some(given) => given
      None => read_octal(header, 136, 12)
    }
    out.push({
      name,
      data: if bodies && (flag == b'0' || flag == b'\x00' || flag == b'7') {
        body.to_owned()
      } else {
        b""
      },
      kind: kind_of(flag),
      mode: read_octal(header, 100, 8).to_int() & 0o7777,
      mtime,
      uid: read_octal(header, 108, 8).to_int(),
      gid: read_octal(header, 116, 8).to_int(),
      uname: text_of(header[265:265 + 32]),
      gname: text_of(header[297:297 + 32]),
      link,
    })
    let _ = expected
    over_path = None
    over_link = None
    over_mtime = None
    over_size = None
    gnu_name = None
  }
  out
}

///|
/// Every entry's name, which still has to walk the archive: tar has no index.
pub fn names(archive : BytesView) -> Array[String] raise @moonzip.Refused {
  scan(archive, -1, false).map(entry => entry.name)
}

///|
/// Whether a block is all zeroes, which is how an archive says it has ended.
fn is_zero(archive : BytesView, at : Int32) -> Bool {
  let mut i = 0
  while i < block {
    if archive[at + i] != b'\x00' {
      return false
    }
    i += 1
  }
  true
}

///|
/// An octal — or base-256 — number out of a fixed-width field.
fn read_octal(header : BytesView, at : Int32, width : Int32) -> Int64 {
  if (header[at].to_int() & 0x80) != 0 {
    // Base 256: the top bit of the first byte is the marker, and the rest of
    // that byte is the most significant digit.
    let mut value = (header[at].to_int() & 0x7F).to_int64()
    for i in 1..<width {
      value = (value << 8) | header[at + i].to_uint().to_int64()
    }
    return value
  }
  let mut value = 0L
  let mut i = 0
  while i < width {
    let b = header[at + i].to_int()
    if b == 0 || b == 32 {
      // A field may be space-padded instead of NUL-padded; either ends it.
      break
    }
    guard b >= 48 && b <= 55 else { break }
    value = value * 8L + (b - 48).to_int64()
    i += 1
  }
  value
}

///|
/// A text field, up to its first NUL.
fn text_of(raw : BytesView) -> String {
  let mut end = 0
  while end < raw.length() && raw[end] != b'\x00' {
    end += 1
  }
  let out = StringBuilder()
  for i in 0..<end {
    out.write_char(raw[i].to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
/// The `keyword=value` records in a pax extended header.
fn pax_records_of(body : BytesView) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  let mut at = 0
  while at < body.length() {
    // Each record starts with its own total length in decimal.
    let mut digits = 0
    while at + digits < body.length() {
      let b = body[at + digits].to_int()
      if b < 48 || b > 57 {
        break
      }
      digits += 1
    }
    if digits == 0 {
      break
    }
    let total = match decimal(text_of(body[at:at + digits])) {
      Some(value) => value.to_int()
      None => break
    }
    if total <= 0 || at + total > body.length() {
      break
    }
    let record = body[at + digits + 1:at + total - 1]
    let mut split = 0
    while split < record.length() && record[split] != b'=' {
      split += 1
    }
    out.push((text_of(record[0:split]), text_of(record[split + 1:])))
    at += total
  }
  out
}

///|
/// A decimal integer, which is what pax records carry. `None` for anything that
/// is not one, so a damaged record is skipped rather than turned into a zero.
fn decimal(text : String) -> Int64? {
  if text.length() == 0 {
    return None
  }
  let mut at = 0
  let mut negative = false
  if text.at(0) == '-' {
    negative = true
    at = 1
  }
  if at >= text.length() {
    return None
  }
  let mut value = 0L
  while at < text.length() {
    let c = text.at(at).to_int()
    if c < 48 || c > 57 {
      return None
    }
    value = value * 10L + (c - 48).to_int64()
    at += 1
  }
  Some(if negative { -value } else { value })
}

///|
/// A tarball: the archive gzipped, which is what `.tar.gz` and `.tgz` are.
///
/// The two formats stack cleanly — gzip compresses the bytes, and the bytes are
/// a tar archive — so this is three lines rather than a format of its own. The
/// compression is of the whole archive, which is why a tarball compresses far
/// better than the same files compressed one at a time: gzip sees every member's
/// redundancy, not just each member's own.
pub fn targz(entries : ArrayView[Entry], level~ : Int32 = 6) -> Bytes {
  @gzip.gzip(tar(entries)[:], level~)
}

///|
/// Read a tarball.
pub fn untargz(
  archive : BytesView,
  limit? : Int32,
) -> Array[Entry] raise @moonzip.Refused {
  untar(@gzip.gunzip(archive)[:], limit?)
}
