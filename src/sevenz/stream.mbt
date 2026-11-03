// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A 7z writer that takes the archive an entry at a time.
///
/// The one-shot [`sevenz`](#sevenz) function holds every member's data, every
/// folder's compressed form and the directory before it hands anything back, so
/// an archive of a gigabyte costs a gigabyte and a half of memory. This writer
/// costs one folder: an entry is compressed as it arrives, and the bytes that
/// compression produced are handed straight to the caller.
///
/// The order of the three calls is fixed by the format rather than by this
/// design. A 7z archive starts with a thirty-two byte header that says where the
/// directory sits and how long it is — numbers nobody can know until the last
/// folder has been written — so those bytes are written *last* and put *first*:
///
/// ```mbt nocheck
/// let w = @sevenz.Writer::new(level=6)
/// let mut body : Array[Byte] = []
/// for entry in entries {
///   for b in w.add(entry) {
///     body.push(b)          // write it wherever the archive is going
///   }
/// }
/// let directory = w.finish()
/// let start = w.signature()  // valid once finish has run
/// ```
///
/// `signature` before `finish` is a bug the caller would only see as an archive
/// 7-Zip refuses, so it aborts instead of returning something plausible.
struct Writer {
  level : Int32
  how : Method
  solid : Bool
  /// The folders finished so far.
  folders : Array[Packed]
  /// How many members each folder holds, in folder order.
  counts : Array[Int32]
  /// Every member's size and checksum, in the order they were added.
  sizes : Array[Int64]
  crcs : Array[UInt32]
  /// The directory's view of the members: everything but their data.
  listed : Array[Entry]
  /// Whether each member has data, which the directory records and the data
  /// itself cannot be asked for once it has been compressed.
  blanks : Array[Bool]
  /// The folder being written, or `None` between folders.
  mut open : Growing?
  /// The directory, once `finish` has built it.
  mut directory : Bytes
  mut closed : Bool
}

///|
/// A folder under construction: the coder that will describe it, and whatever
/// holds its packed bytes while it is being written.
priv struct Growing {
  coder : Coder
  /// Packed bytes: what a streaming compressor emitted, or the whole compressed
  /// folder once it is done.
  data : Array[Byte]
  /// The streaming compressor, for the method that has one.
  lzma : @lzma.Writer?
  /// The folder's plain bytes, for the methods that cannot stream.
  buffer : Array[Byte]
  mut unpacked : Int64
}

///|
fn Growing::new(how : Method, level : Int32) -> Growing {
  match how {
    Copy =>
      {
        coder: { codec: [0x00], props: b"", num_in: 1, num_out: 1, },
        data: [],
        lzma: None,
        buffer: [],
        unpacked: 0L,
      }
    Lzma =>
      {
        coder: {
          codec: [0x03, 0x01, 0x01],
          props: coder_properties(level),
          num_in: 1,
          num_out: 1,
        },
        data: [],
        // A folder carries the properties itself, so the stream inside one is
        // the coder's output with no header of its own.
        lzma: Some(@lzma.Writer::new(level~, header=false)),
        buffer: [],
        unpacked: 0L,
      }
    Lzma2 =>
      {
        coder: {
          codec: [0x21],
          props: Bytes::from_array([
            @lzma.dict_code(@lzma.dictionary_for(level)).to_byte(),
          ]),
          num_in: 1,
          num_out: 1,
        },
        data: [],
        lzma: None,
        buffer: [],
        unpacked: 0L,
      }
  }
}

///|
/// The five property bytes an LZMA coder carries: the coder's own byte and the
/// dictionary size, little-endian.
fn coder_properties(level : Int32) -> Bytes {
  let dictionary = @lzma.dictionary_for(level)
  let settings : Array[Byte] = [@lzma.properties_of(3, 0, 2).to_byte()]
  for b in le32(dictionary.reinterpret_as_uint()) {
    settings.push(b)
  }
  Bytes::from_array(settings)
}

///|
/// A writer that has written nothing yet.
pub fn Writer::new(
  level~ : Int32 = 6,
  how~ : Method = Lzma,
  solid~ : Bool = true,
) -> Writer {
  {
    level: if level < 0 {
      0
    } else if level > 9 {
      9
    } else {
      level
    },
    how,
    solid,
    folders: [],
    counts: [],
    sizes: [],
    crcs: [],
    listed: [],
    blanks: [],
    open: None,
    directory: b"",
    closed: false,
  }
}

///|
/// Add a member, and take whatever compressed bytes that produced.
///
/// A member with no data — a directory, or an empty file — joins the directory
/// and no folder, which is the same thing 7-Zip does with one.
pub fn Writer::add(self : Writer, entry : Entry) -> Bytes {
  if self.closed {
    abort("7z: the writer is finished")
  }
  let blank = entry.kind == Directory || entry.data.length() == 0
  self.listed.push({
    name: entry.name,
    data: b"",
    kind: entry.kind,
    mtime: entry.mtime,
    attributes: entry.attributes,
  })
  self.blanks.push(blank)
  if blank {
    // A member with no data has no stream, so it appears in no size table: the
    // tables describe streams, and the directory says which members have none.
    return b""
  }
  self.sizes.push(entry.data.length().to_int64())
  self.crcs.push(@moonzip.crc32(entry.data[:]))
  // A non-solid archive gives every member its own folder, so the folder a
  // member is in has to be closed before the next one starts.
  let made : Array[Byte] = []
  if !self.solid {
    for b in self.close_folder() {
      made.push(b)
    }
  }
  if self.open is None {
    self.open = Some(Growing::new(self.how, self.level))
    self.counts.push(0)
  }
  let folder = match self.open {
    Some(f) => f
    None => abort("7z: a folder that was not opened")
  }
  folder.unpacked += entry.data.length().to_int64()
  match folder.lzma {
    Some(writer) =>
      for b in writer.push(entry.data[:]) {
        made.push(b)
        folder.data.push(b)
      }
    None =>
      // No streaming encoder for this method: the folder's plain bytes wait
      // here until it closes, which is the solid unit and no larger.
      for b in entry.data {
        folder.buffer.push(b)
      }
  }
  let last = self.counts.length() - 1
  self.counts[last] = self.counts[last] + 1
  Bytes::from_array(made)
}

///|
/// Close the folder being written, if there is one, and take the bytes its
/// compressor still holds.
fn Writer::close_folder(self : Writer) -> Bytes {
  let folder = match self.open {
    Some(f) => f
    None => return b""
  }
  let made : Array[Byte] = []
  match folder.lzma {
    Some(writer) =>
      for b in writer.finish() {
        made.push(b)
      }
    None =>
      if self.how is Lzma2 {
        let packed = @lzma.lzma2(
          Bytes::from_array(folder.buffer)[:],
          @lzma.dictionary_for(self.level),
          self.level,
        )
        for b in packed {
          made.push(b)
        }
      } else {
        for b in folder.buffer {
          made.push(b)
        }
      }
  }
  for b in made {
    folder.data.push(b)
  }
  self.folders.push({
    coder: folder.coder,
    data: Bytes::from_array(folder.data),
    unpacked: folder.unpacked,
  })
  self.open = None
  Bytes::from_array(made)
}

///|
/// The directory, and the end of the archive.
///
/// The bytes returned here are the ones that go after every folder's data.
pub fn Writer::finish(self : Writer) -> Bytes {
  if self.closed {
    abort("7z: the writer is finished")
  }
  let trailing = self.close_folder()
  self.closed = true
  let header = if self.listed.length() == 0 {
    b""
  } else {
    build_header(
      self.listed[:],
      self.blanks,
      self.folders,
      self.counts,
      self.sizes,
      self.crcs,
    )
  }
  self.directory = header
  let out : Array[Byte] = []
  for b in trailing {
    out.push(b)
  }
  for b in header {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// The thirty-two bytes that go in front of everything.
///
/// Only valid once `finish` has run: the first field is where the directory
/// starts, which is the length of the packed data.
pub fn Writer::signature(self : Writer) -> Bytes {
  if !self.closed {
    abort("7z: the signature is not known until the archive is finished")
  }
  let start : Array[Byte] = []
  for b in le64(folders_data_size(self.folders)) {
    start.push(b)
  }
  for b in le64(self.directory.length().to_int64()) {
    start.push(b)
  }
  for b in le32(@moonzip.crc32(self.directory[:])) {
    start.push(b)
  }
  let out : Array[Byte] = []
  for b in magic {
    out.push(b.to_byte())
  }
  out.push(b'\x00')
  out.push(b'\x04')
  for b in le32(@moonzip.crc32(Bytes::from_array(start)[:])) {
    out.push(b)
  }
  for b in start {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// A reader that takes the archive a piece at a time.
///
/// A 7z archive keeps its directory at the *end* — the only place a writer can
/// put a table that describes streams it has not written yet — so nothing can be
/// cut into members until the last bytes have arrived. What is streamed is the
/// input: the reader holds what it has been given, checks the signature as soon
/// as six bytes are in, and decodes folder by folder when the directory arrives,
/// keeping one folder's output at a time rather than the whole archive's.
///
/// ```mbt nocheck
/// let reader = @sevenz.Reader::new()
/// for piece in pieces {
///   reader.push(piece[:])
/// }
/// let members = reader.finish()
/// ```
struct Reader {
  /// Everything pushed so far, with what has been consumed dropped from the
  /// front.
  mut held : Array[Byte]
  limit : Int32
  /// Whether the signature has been checked.
  mut started : Bool
  mut closed : Bool
}

///|
pub fn Reader::new(limit? : Int32) -> Reader {
  {
    held: [],
    limit: match limit {
      Some(n) => n
      None => -1
    },
    started: false,
    closed: false,
  }
}

///|
/// Feed a piece of the archive.
///
/// The signature and the version bytes are checked as soon as they are in, so a
/// file that is not a 7z archive is refused on its first six bytes rather than
/// after a gigabyte of them.
pub fn Reader::push(
  self : Reader,
  data : BytesView,
) -> Unit raise @moonzip.Refused {
  if self.closed {
    abort("7z: the reader is finished")
  }
  let at = self.held.length()
  self.held.resize(at + data.length(), b'\x00')
  for i in 0..<data.length() {
    self.held[at + i] = data[i]
  }
  if !self.started && self.held.length() >= 6 {
    for i in 0..<6 {
      if self.held[i].to_int() != magic[i] {
        raise @moonzip.Header(at=0, what="this is not a 7z archive")
      }
    }
    self.started = true
  }
}

///|
/// The directory has arrived: decode what it describes and hand back the members.
pub fn Reader::finish(self : Reader) -> Array[Entry] raise @moonzip.Refused {
  if self.closed {
    abort("7z: the reader is finished")
  }
  self.closed = true
  let archive = Bytes::from_array(self.held[:])
  self.held = []
  if !self.started && archive.length() >= 6 {
    for i in 0..<6 {
      if archive[i].to_int() != magic[i] {
        raise @moonzip.Header(at=0, what="this is not a 7z archive")
      }
    }
  }
  un7z(archive[:], limit=self.limit)
}
