// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What an entry is. 7-Zip records it in the file attributes rather than in a
/// type field, which is why this is derived rather than read.
#derive(Eq, Debug)
pub(all) enum Kind {
  File
  Directory
}

///|
pub extend Kind with Eq::{equal, not_equal}

///|
pub extend Kind with Debug::{to_repr}

///|
/// One member of an archive.
///
/// `data` is empty for a directory and for a file that had no content, which are
/// two different things: `kind` tells them apart, and `size` does not.
#derive(Eq, Debug)
pub(all) struct Entry {
  name : String
  data : Bytes
  kind : Kind
  /// Last modification, in Unix seconds. 7-Zip stores a Windows FILETIME, which
  /// is a hundred-nanosecond count since 1601, so a value read back is exact and
  /// a value that was never recorded is zero.
  mtime : Int64
  /// The Windows attribute word, kept because it is the only place 7-Zip records
  /// "hidden", "read-only" and "directory".
  attributes : UInt32
}

///|
pub extend Entry with Eq::{equal, not_equal}

///|
pub extend Entry with Debug::{to_repr}

///|
pub fn Entry::new(
  name : String,
  data : Bytes,
  mtime~ : Int64 = 0L,
  attributes~ : UInt32 = 0x20U,
) -> Entry {
  { name, data, kind: File, mtime, attributes, }
}

///|
pub fn Entry::directory(name : String, mtime~ : Int64 = 0L) -> Entry {
  { name, data: b"", kind: Directory, mtime, attributes: 0x10U, }
}

///|
/// The directory bit in a Windows attribute word.
let attribute_directory : UInt32 = 0x10U

///|
/// Where an archive lives when it is not one block of memory: a file, a mapping, a
/// range of some larger store.
///
/// A 7z directory is written after the folders it describes and the folders
/// themselves are scattered through the file, so a reader that can only move
/// forward cannot read one without holding all of it. This is the contract that
/// lets the reader ask for one folder at a time and forget it again; a file, a
/// memory mapping and a block of bytes are all conforming sources.
pub(open) trait RandomAccess {
  /// Up to `len` bytes at `offset`, fewer when the source ends first.
  fn read(Self, Int64, Int32) -> Bytes raise @moonzip.Refused
  /// How many bytes the source holds.
  fn size(Self) -> Int64
}

///|
/// A source over bytes already in memory, which is what `un7z` reads.
priv struct Memory {
  data : Bytes
}

///|
fn Memory::new(data : BytesView) -> Memory {
  { data: data.to_owned(), }
}

///|
impl RandomAccess for Memory with fn read(self, offset, len) {
  let size = self.data.length().to_int64()
  if offset < 0L || len < 0 || offset > size {
    raise @moonzip.Truncated(at=0)
  }
  let stop = if offset + len.to_int64() > size {
    size
  } else {
    offset + len.to_int64()
  }
  self.data[offset.to_int():stop.to_int()].to_owned()
}

///|
impl RandomAccess for Memory with fn size(self) {
  self.data.length().to_int64()
}

///|
/// Read a 7z archive held in one block of memory.
///
/// ```moonbit nocheck
/// let members = @sevenz.un7z(archive[:])
/// ```
///
/// `limit` is how much output the caller is prepared to hold. An archive declares
/// its unpacked sizes, so this is checked before the allocation rather than after.
pub fn un7z(
  data : BytesView,
  limit? : Int32,
) -> Array[Entry] raise @moonzip.Refused {
  un7z_from(Memory::new(data), limit?)
}

///|
/// Read a 7z archive through a random-access source.
///
/// The signature header and the directory are read first — a few kilobytes, and
/// they have to be, since the directory is what says where the folders are. After
/// that each folder is read, decoded and cut into its members before the next one
/// is touched, so the archive itself is never held: what a caller pays for beyond
/// the members is one folder, packed and unpacked.
///
/// ```moonbit nocheck
/// let members = @sevenz.un7z_from(file)
/// ```
pub fn un7z_from(
  source : &RandomAccess,
  limit? : Int32,
) -> Array[Entry] raise @moonzip.Refused {
  let bound = match limit {
    Some(n) => n
    None => -1
  }
  let opened = open_archive(source)
  let payloads = decode_streams(source, opened.streams, bound)
  assemble(opened.files, payloads, bound)
}

///|
/// What the directory says, and the streams it points at, without decoding any of
/// them. A listing costs this and nothing else.
priv struct Opened {
  files : Array[FileRec]
  streams : Streams
}

///|
/// Read the signature header and the directory.
fn open_archive(source : &RandomAccess) -> Opened raise @moonzip.Refused {
  let size = source.size()
  if size < 32L {
    raise @moonzip.Truncated(at=size.to_int())
  }
  // The signature header is fixed and small; everything after it is read where
  // the directory says it is, which is what keeps this from holding the archive.
  let start = source.read(0L, 32)
  let c = Cursor::new(start[:])
  for i in 0..<6 {
    if c.byte() != magic[i] {
      raise @moonzip.Header(at=0, what="this is not a 7z archive")
    }
  }
  let _major = c.byte()
  let _minor = c.byte()
  let start_crc = c.u32le()
  // The start header's checksum covers the three fields after it, which is what
  // tells a reader the archive was not truncated before it even looks for the
  // header.
  let start_span = start[12:32]
  let got_start = @moonzip.crc32(start_span)
  if got_start != start_crc {
    raise @moonzip.Checksum(want=start_crc, got=got_start)
  }
  let next_offset = c.u64le()
  let next_size = c.u64le()
  let next_crc = c.u32le()
  let header_at = 32L + next_offset
  if header_at < 32L || next_size < 0L || header_at + next_size > size {
    raise @moonzip.Truncated(at=size.to_int())
  }
  if next_size == 0L {
    // No header at all, which is what an archive of nothing is: the signature
    // header and the two end bytes. It is legal, and it is how 7-Zip spares a
    // file whose only content is its own name.
    return {
      files: [],
      streams: Streams::{ pack: None, folders: [], subs: None, },
    }
  }
  let raw = source.read(header_at, next_size.to_int())
  let got_next = @moonzip.crc32(raw)
  if got_next != next_crc {
    raise @moonzip.Checksum(want=next_crc, got=got_next)
  }
  // The header may itself be compressed. That is not an optimisation: it is how a
  // thousand-file archive keeps its directory under a few kilobytes.
  let hc = Cursor::new(raw)
  let header_bytes = if hc.peek() == k_encoded_header {
    hc.byte() |> ignore
    let streams = read_streams(hc)
    header_payload(source, streams)
  } else {
    raw
  }
  read_directory(header_bytes)
}

///|
/// The decoded header, from the streams that describe it.
fn header_payload(
  source : &RandomAccess,
  streams : Streams,
) -> Bytes raise @moonzip.Refused {
  // No bound: the directory has to be decoded to know anything at all, and the
  // format states its size in the signature header, so a bomb here is a bomb the
  // caller asked for by opening the file.
  let made = decode_streams(source, streams, -1)
  if made.length() != 1 {
    raise @moonzip.Header(at=0, what="a header that is not one stream")
  }
  made[0]
}

///|
fn read_directory(header : Bytes) -> Opened raise @moonzip.Refused {
  let c = Cursor::new(header[:])
  if c.byte() != k_header {
    raise @moonzip.Header(
      at=0,
      what="a header that does not start with a header id",
    )
  }
  let empty = Streams::{ pack: None, folders: [], subs: None, }
  let mut streams = empty
  let mut files : Array[FileRec] = []
  let mut next = c.peek()
  if next == k_archive_properties || next == k_additional_streams {
    raise @moonzip.Header(
      at=c.at,
      what="an archive property block or an additional stream, which is not implemented",
    )
  }
  if next == k_main_streams {
    c.byte() |> ignore
    streams = read_streams(c)
    next = c.peek()
  }
  if next == k_files_info {
    c.byte() |> ignore
    files = read_files(c, streams)
    next = c.peek()
  }
  if next != k_end {
    raise @moonzip.Header(
      at=c.at,
      what="a header that does not end where it should",
    )
  }
  { files, streams, }
}

///|
/// Pair the directory with the payloads, in order.
fn assemble(
  files : Array[FileRec],
  payloads : Array[Bytes],
  limit : Int32,
) -> Array[Entry] raise @moonzip.Refused {
  // The files that have data take the payloads in order; the ones that do not are
  // directories, empty files and deletions, and they take nothing.
  let out : Array[Entry] = []
  let mut next_payload = 0
  let mut total = 0
  for i in 0..<files.length() {
    let file = files[i]
    if file.anti {
      continue
    }
    if file.empty_stream {
      let is_dir = (file.attributes & attribute_directory) != 0U
      out.push({
        name: file.name,
        data: b"",
        kind: if is_dir || !file.empty_file {
          Directory
        } else {
          File
        },
        mtime: file.mtime,
        attributes: file.attributes,
      })
      continue
    }
    if next_payload >= payloads.length() {
      raise @moonzip.Header(
        at=0,
        what="fewer streams than the file table needs",
      )
    }
    let body = payloads[next_payload]
    next_payload += 1
    total += body.length()
    if limit >= 0 && total > limit {
      raise @moonzip.TooBig(limit~)
    }
    out.push({
      name: file.name,
      data: body,
      kind: File,
      mtime: file.mtime,
      attributes: file.attributes,
    })
  }
  out
}

///|
/// Every folder decoded and cut into its substreams, in archive order.
fn decode_streams(
  source : &RandomAccess,
  streams : Streams,
  limit : Int32,
) -> Array[Bytes] raise @moonzip.Refused {
  let out : Array[Bytes] = []
  let pack = match streams.pack {
    Some(p) => p
    None => return out
  }
  if pack.sizes.length() != streams.folders.length() {
    raise @moonzip.Header(
      at=0,
      what="a pack table whose stream count does not match its folder count",
    )
  }
  // Where the packed bytes begin: the format counts from the byte after the
  // signature header, so an archive can be moved without rewriting its offsets.
  let mut at = 32L + pack.pos
  let whole = source.size()
  for f in 0..<streams.folders.length() {
    let size = pack.sizes[f]
    if size < 0L || at + size > whole {
      raise @moonzip.Truncated(at=whole.to_int())
    }
    // One folder, read where it lies and released when the next one starts.
    let packed = source.read(at, size.to_int())
    at = at + size
    if pack.defined[f] {
      let got = @moonzip.crc32(packed)
      if got != pack.crcs[f] {
        raise @moonzip.Checksum(want=pack.crcs[f], got~)
      }
    }
    let body = decode_folder(streams.folders[f], packed, limit)

    let folder = streams.folders[f]
    let counts = match streams.subs {
      Some(sub) => sub.counts[f]
      None => 1
    }
    // A folder's own checksum covers all of its output, which is the whole folder
    // only when it holds one file. With more, the checksums are in the substream
    // table below instead.
    if folder.crc_defined && counts == 1 {
      let got = @moonzip.crc32(body[:])
      if got != folder.crc {
        raise @moonzip.Checksum(want=folder.crc, got~)
      }
    }
    let mut cursor = 0
    let index = substream_base(streams, f)
    for k in 0..<counts {
      let size = match streams.subs {
        Some(sub) => sub.sizes[index + k]
        None => folder_size(folder)
      }
      if size < 0L || cursor.to_int64() + size > body.length().to_int64() {
        raise @moonzip.Header(
          at=0,
          what="a substream that runs past its folder",
        )
      }
      let piece = body[cursor:cursor + size.to_int()].to_owned()
      cursor += size.to_int()
      match streams.subs {
        Some(sub) =>
          if sub.defined[index + k] {
            let got = @moonzip.crc32(piece)
            if got != sub.crcs[index + k] {
              raise @moonzip.Checksum(want=sub.crcs[index + k], got~)
            }
          }
        None => ()
      }
      out.push(piece)
    }
    if limit >= 0 {
      let mut total = 0
      for piece in out {
        total += piece.length()
      }
      if total > limit {
        raise @moonzip.TooBig(limit~)
      }
    }
  }
  out
}

///|
/// Where the substreams of folder `f` begin in the flat size table.
fn substream_base(streams : Streams, f : Int32) -> Int32 {
  match streams.subs {
    None => 0
    Some(sub) => {
      let mut base = 0
      for i in 0..<f {
        base += sub.counts[i]
      }
      base
    }
  }
}

///|
/// The names in an archive, without decompressing anything.
///
/// Reading a directory should not cost the directory's contents, which for a
/// solid archive would be the whole thing.
pub fn names(archive : BytesView) -> Array[String] raise @moonzip.Refused {
  names_from(Memory::new(archive))
}

///|
/// The names in an archive a source is reading, without decompressing anything.
pub fn names_from(
  source : &RandomAccess,
) -> Array[String] raise @moonzip.Refused {
  // The header only, which for an archive whose directory is itself compressed
  // means decompressing the directory and nothing else.
  open_archive(source).files.map(file => file.name)
}
