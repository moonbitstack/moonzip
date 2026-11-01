// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Spanned volumes: the older multi-disk model, where each piece is a disk of
/// one archive and the headers carry disk numbers and per-disk offsets.
///
/// This is different from [`split`](#split), which cuts a finished archive into
/// byte ranges and leaves every offset absolute. A spanned archive records, for
/// each member, the disk it starts on and where on that disk it starts, and the
/// end record names the disk the central directory begins on and where. A reader
/// that has all the volumes translates those back to one coordinate space and
/// then reads it — which is exactly what [`unzip_spanned`](#unzip_spanned) does.
///
/// The writer keeps every offset in thirty-two bits, so it refuses a member that
/// would need Zip64 rather than writing a spanned archive the wide form cannot
/// agree with. For volumes under four gigabytes and fewer than sixty-five
/// thousand of them, that is every archive this package writes.
///
/// The end record must lie wholly on the last disk — a reader handed that piece
/// alone finds the directory from it — so the last disk begins at the largest
/// multiple of the requested size that does not pass the record. Every disk
/// before it is exactly the size asked for; the last is the one that may be
/// larger, by the length of the directory's tail and the record.

///|
fn sp16(b : Array[Byte], i : Int32) -> Int32 {
  b[i].to_int() | (b[i + 1].to_int() << 8)
}

///|
fn sp32(b : Array[Byte], i : Int32) -> UInt32 {
  let mut v = 0U
  for k in 0..<4 {
    v = v | (b[i + k].to_uint() << (k * 8))
  }
  v
}

///|
fn sp_put16(b : Array[Byte], i : Int32, v : Int32) -> Unit {
  b[i] = (v & 0xFF).to_byte()
  b[i + 1] = ((v >> 8) & 0xFF).to_byte()
}

///|
fn sp_put32(b : Array[Byte], i : Int32, v : UInt32) -> Unit {
  for k in 0..<4 {
    b[i + k] = ((v >> (k * 8)) & 0xFFU).to_byte()
  }
}

///|
/// Write an archive as spanned volumes of at most `size` bytes each.
///
/// Each member's central-directory record is rewritten with the disk it starts
/// on and its offset from that disk's first byte, and the end record is rewritten
/// with the last disk's number and the directory's disk-relative offset. The
/// arguments after `size` are [`zip`](#zip)'s.
///
/// A caller with a file system writes volume `i` under the name
/// [`volume_names`](#volume_names) gives it. The result differs from a
/// [`split`](#split) only in those header fields: the bytes of the members are
/// the same, so a mode that has no need of disk numbers should use the simpler
/// one.
pub fn zip_spanned(
  entries : ArrayView[Entry],
  size : Int32,
  level~ : Int32 = level,
  codecs~ : ArrayView[&Codec] = [],
  descriptor~ : Bool = false,
  password? : String,
  aes~ : Int32 = 0,
  ae~ : Int32 = 1,
) -> Array[Bytes] {
  if size <= 0 {
    abort("zip: a volume must hold at least one byte")
  }
  let writer = Writer::new(
    level~,
    zip64=false,
    descriptor~,
    password?,
    aes~,
    ae~,
  )
  let out : Array[Byte] = []
  for entry in entries {
    for b in writer.add(entry, codecs~) {
      out.push(b)
    }
  }
  let cd_start = writer.at
  for b in writer.finish() {
    out.push(b)
  }
  let count = writer.placed.length()
  for placed in writer.placed {
    if placed.widened {
      abort("zip: spanned archives here do not carry Zip64 offsets")
    }
  }
  let total = out.length().to_int64()
  let width = size.to_int64()
  // The end record must lie wholly on the last disk, or a reader handed that
  // piece alone cannot find it. So the last disk begins at the largest multiple
  // of the volume size that does not pass the record's first byte: every disk
  // before it is exactly the size asked for, and the last carries the
  // directory's tail and the end record, which is what makes it a little larger.
  let last_start = (total - 22L) / width * width
  let last = (last_start / width).to_int()
  // Rewrite each directory record: the disk the member starts on, and its
  // offset from that disk's first byte.
  let mut at = cd_start.to_int()
  for placed in writer.placed {
    let disk = (placed.offset / width).to_int()
    let rel = (placed.offset - disk.to_int64() * width).to_int()
    sp_put16(out, at + 34, disk)
    sp_put32(out, at + 42, rel.reinterpret_as_uint())
    at += 46 + sp16(out, at + 28) + sp16(out, at + 30) + sp16(out, at + 32)
  }
  // The end record lives on the last disk, names the disk the directory starts
  // on, and gives that disk's relative offset for it.
  let end = out.length() - 22
  let cd_disk = (cd_start / width).to_int()
  let cd_rel = (cd_start - cd_disk.to_int64() * width).to_int()
  let mut on_last = 0
  let mut walk = cd_start.to_int()
  for _ in 0..<count {
    if walk.to_int64() >= last_start {
      on_last += 1
    }
    walk += 46 +
      sp16(out, walk + 28) +
      sp16(out, walk + 30) +
      sp16(out, walk + 32)
  }
  sp_put16(out, end + 4, last)
  sp_put16(out, end + 6, cd_disk)
  sp_put16(out, end + 8, on_last)
  sp_put16(out, end + 10, count)
  sp_put32(out, end + 16, cd_rel.reinterpret_as_uint())
  let bytes = Bytes::from_array(out)
  let volumes : Array[Bytes] = []
  let stop = last_start.to_int()
  let n = total.to_int()
  let mut from = 0
  while from < stop {
    volumes.push(bytes[from:from + size].to_owned())
    from += size
  }
  volumes.push(bytes[stop:n].to_owned())
  volumes
}

///|
/// Read an archive that arrived as spanned volumes.
///
/// The volumes are joined, each directory record's disk and relative offset are
/// translated back to one coordinate space, and the result is read exactly as
/// [`unzip`](#unzip) reads a single buffer. Volumes must be in disk order.
pub fn unzip_spanned(
  volumes : ArrayView[Bytes],
  limit? : Int32,
  codecs~ : ArrayView[&Codec] = [],
  password? : String,
) -> Array[Entry] raise @moonzip.Refused {
  if volumes.length() == 0 {
    raise @moonzip.Header(
      at=0,
      what="a spanned archive needs at least one volume",
    )
  }
  // Where each volume begins in the joined stream.
  let starts : Array[Int64] = []
  let mut acc = 0L
  for v in volumes {
    starts.push(acc)
    acc = acc + v.length().to_int64()
  }
  let buf = join(volumes).to_array()
  let total = buf.length()
  let mut end = total - 22
  let floor = if total > 22 + 65535 { total - 22 - 65535 } else { 0 }
  let mut found = false
  while end >= floor {
    if sp32(buf, end) == 0x06054B50U {
      found = true
      break
    }
    end -= 1
  }
  guard found else {
    raise @moonzip.Header(at=total, what="no end-of-central-directory record")
  }
  if sp16(buf, end + 10) == 0xFFFF || sp32(buf, end + 16) == 0xFFFFFFFFU {
    raise @moonzip.Header(
      at=end,
      what="a Zip64 spanned archive, which this reader does not carry",
    )
  }
  let cd_disk = sp16(buf, end + 6)
  guard cd_disk >= 0 && cd_disk < starts.length() else {
    raise @moonzip.Header(
      at=end + 6,
      what="a directory on a disk that is not here",
    )
  }
  let cd_start = starts[cd_disk] + sp32(buf, end + 16).to_int64()
  let count = sp16(buf, end + 10)
  // Put every entry back into the joined stream's coordinates, then hand the
  // whole thing to the ordinary reader.
  let mut at = cd_start.to_int()
  for _ in 0..<count {
    guard at + 46 <= total && sp32(buf, at) == 0x02014B50U else {
      raise @moonzip.Header(
        at~,
        what="a central directory entry without its signature",
      )
    }
    let disk = sp16(buf, at + 34)
    guard disk >= 0 && disk < starts.length() else {
      raise @moonzip.Header(
        at=at + 34,
        what="an entry on a disk that is not here",
      )
    }
    let here = starts[disk] + sp32(buf, at + 42).to_int64()
    sp_put32(buf, at + 42, here.to_int().reinterpret_as_uint())
    sp_put16(buf, at + 34, 0)
    at += 46 + sp16(buf, at + 28) + sp16(buf, at + 30) + sp16(buf, at + 32)
  }
  sp_put16(buf, end + 4, 0)
  sp_put16(buf, end + 6, 0)
  sp_put16(buf, end + 8, count)
  sp_put16(buf, end + 10, count)
  sp_put32(buf, end + 16, cd_start.to_int().reinterpret_as_uint())
  unzip(Bytes::from_array(buf)[:], limit?, codecs~, password?)
}
