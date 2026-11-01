// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Volume splitting: one archive carried in several files, `archive.z01`,
/// `archive.z02`, … and finally `archive.zip`.
///
/// A split archive is the same bytes as the whole one, cut at fixed boundaries.
/// Nothing in the format has to change — the central directory is still the last
/// thing in the stream, and its offsets are still measured from the beginning of
/// the archive — so rejoining the pieces in order gives an ordinary archive back.
/// This is the "split for transport" model that `zip -s` writes and that every
/// reader understands once the pieces are put back together; it is not the older
/// "spanned" model, where each volume is a separate archive with its own disk
/// number and a seek across files is needed to read one member.
///
/// The pieces are ordinary bytes, so a caller with a file system writes them to
/// the names [`volume_names`](#volume_names) gives. This package never touches a
/// file; the split and the join are pure functions over buffers.

///|
/// Cut a finished archive into volumes of at most `size` bytes, in order.
///
/// Every volume but the last is exactly `size` bytes; the last holds the rest,
/// which may be less. An archive that fits in one volume comes back as a single
/// volume, and an empty one as an empty array. `size` must be positive: a volume
/// that holds nothing would be a loop that never advances.
pub fn split(archive : BytesView, size : Int32) -> Array[Bytes] {
  if size <= 0 {
    abort("zip: a volume must hold at least one byte")
  }
  let out : Array[Bytes] = []
  let total = archive.length()
  let mut at = 0
  while at < total {
    let end = if at + size > total { total } else { at + size }
    out.push(archive[at:end].to_owned())
    at = end
  }
  out
}

///|
/// Put the volumes back together, in the order they were split.
///
/// The result is the archive the volumes were cut from, which is what
/// [`unzip`](#unzip) and [`names`](#names) expect.
pub fn join(volumes : ArrayView[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for volume in volumes {
    for b in volume {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
/// The file names a split archive conventionally uses.
///
/// For an archive called `base`, the first `count - 1` volumes are `base.z01`,
/// `base.z02`, … and the last is `base.zip` — the extension the tools look for,
/// which is why the final volume carries the one that says "zip" rather than
/// another number. A single volume is just `base.zip`.
pub fn volume_names(base : String, count : Int32) -> Array[String] {
  let out : Array[String] = []
  for i in 0..<count {
    if i + 1 == count {
      out.push(base + ".zip")
    } else {
      let n = i + 1
      let digits = if n < 10 { "0" + n.to_string() } else { n.to_string() }
      out.push(base + ".z" + digits)
    }
  }
  out
}

///|
/// Write an archive and split it in one step.
///
/// The arguments are [`zip`](#zip)'s, plus the volume size. This is the call a
/// caller with a large archive and a size limit wants: it never builds the whole
/// stream twice, and the volumes are the ones [`unzip_split`](#unzip_split)
/// reads back.
pub fn zip_split(
  entries : ArrayView[Entry],
  size : Int32,
  level~ : Int32 = level,
  codecs~ : ArrayView[&Codec] = [],
  zip64~ : Bool = false,
  descriptor~ : Bool = false,
  password? : String,
  aes~ : Int32 = 0,
  ae~ : Int32 = 1,
) -> Array[Bytes] {
  split(
    zip(entries, level~, codecs~, zip64~, descriptor~, password?, aes~, ae~)[:],
    size,
  )
}

///|
/// Read an archive that arrived as several volumes.
///
/// The volumes are joined first — a split archive is the same bytes cut at
/// boundaries, so the pieces in order are the archive — and then read exactly as
/// [`unzip`](#unzip) reads one buffer.
pub fn unzip_split(
  volumes : ArrayView[Bytes],
  limit? : Int32,
  codecs~ : ArrayView[&Codec] = [],
  password? : String,
) -> Array[Entry] raise @moonzip.Refused {
  unzip(join(volumes)[:], limit?, codecs~, password?)
}
