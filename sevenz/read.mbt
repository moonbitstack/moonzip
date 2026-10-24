// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One step of a folder's chain: a codec and the properties it needs.
priv struct Coder {
  codec : Array[Int32]
  props : Bytes
  num_in : Int32
  num_out : Int32
}

///|
/// A folder is one compressed stream and the chain of coders that produced it.
///
/// The name is 7-Zip's and it means what `tar` would call a member and what
/// `zip` would call an entry's data — except that a folder can hold several files
/// at once, which is what "solid" means: the compressor saw all of them together
/// and none of them can be extracted without the ones before it.
priv struct Folder {
  coders : Array[Coder]
  unpack_sizes : Array[Int64]
  mut crc : UInt32
  mut crc_defined : Bool
}

///|
priv struct PackInfo {
  /// Where the packed streams start, counted from the byte after the signature
  /// header — so an archive can be moved without rewriting it.
  pos : Int64
  sizes : Array[Int64]
  crcs : Array[UInt32]
  defined : Array[Bool]
}

///|
priv struct SubInfo {
  counts : Array[Int32]
  sizes : Array[Int64]
  crcs : Array[UInt32]
  defined : Array[Bool]
}

///|
priv struct Streams {
  pack : PackInfo?
  folders : Array[Folder]
  subs : SubInfo?
}

///|
priv struct FileRec {
  mut name : String
  mut empty_stream : Bool
  mut empty_file : Bool
  mut anti : Bool
  mut mtime : Int64
  mut attributes : UInt32
}

///|
/// One coder: a flag byte that says how long the method id is and whether
/// properties follow, then the id.
fn read_coder(c : Cursor) -> Coder raise @moonzip.Refused {
  let flag = c.byte()
  let id_size = flag & 0x0F
  let complex = (flag & 0x10) != 0
  let has_props = (flag & 0x20) != 0
  let codec : Array[Int32] = []
  if id_size == 0 {
    // A zero length is not a missing method: it is how COPY is spelled, because
    // the method id for "no compression" is the empty string's worth of one zero
    // byte that does not have to be written.
    codec.push(0x00)
  } else {
    let raw = c.take(id_size)
    for i in 0..<id_size {
      codec.push(raw[i].to_int())
    }
  }
  let mut num_in = 1
  let mut num_out = 1
  if complex {
    num_in = c.uint64().to_int()
    num_out = c.uint64().to_int()
    if num_in < 1 || num_out < 1 || num_in > 64 || num_out > 64 {
      raise @moonzip.Header(
        at=c.at,
        what="a coder with an impossible stream count",
      )
    }
  }
  let props = if has_props {
    let n = c.uint64().to_int()
    if n < 0 || n > 1048576 {
      raise @moonzip.Header(
        at=c.at,
        what="coder properties longer than a megabyte",
      )
    }
    c.take(n).to_owned()
  } else {
    b""
  }
  { codec, props, num_in, num_out, }
}

///|
fn read_folder(c : Cursor) -> Folder raise @moonzip.Refused {
  let count = c.uint64().to_int()
  if count < 1 || count > 64 {
    raise @moonzip.Header(at=c.at, what="a folder with no coders, or too many")
  }
  let coders : Array[Coder] = []
  let mut total_in = 0
  let mut total_out = 0
  for _ in 0..<count {
    let coder = read_coder(c)
    total_in += coder.num_in
    total_out += coder.num_out
    coders.push(coder)
  }
  // The bind pairs say which output feeds which input. Every chain this package
  // writes is linear, and so is almost every archive in the wild; anything else
  // is a graph, and following a graph is a different piece of work.
  let pairs = total_out - 1
  for i in 0..<pairs {
    let to = c.uint64().to_int()
    let from = c.uint64().to_int()
    if to != i + 1 || from != i {
      raise @moonzip.Header(
        at=c.at,
        what="a folder whose coders are not a straight chain, which is not implemented",
      )
    }
  }
  let packed = total_in - pairs
  if packed > 1 {
    // One packed stream needs no index; more than one does, and this package
    // does not read those.
    raise @moonzip.Header(
      at=c.at,
      what="a folder fed by more than one packed stream, which is not implemented",
    )
  }
  { coders, unpack_sizes: [], crc: 0U, crc_defined: false, }
}

///|
fn read_pack_info(c : Cursor) -> PackInfo raise @moonzip.Refused {
  let pos = c.uint64()
  let count = c.uint64().to_int()
  if count < 1 || count > 65536 {
    raise @moonzip.Header(
      at=c.at,
      what="an archive with the wrong number of packed streams",
    )
  }
  let sizes = Array::make(count, 0L)
  let crcs = Array::make(count, 0U)
  let defined = Array::make(count, false)
  let mut at = c.peek()
  if at == k_size {
    c.byte() |> ignore
    for i in 0..<count {
      sizes[i] = c.uint64()
    }
    at = c.peek()
  }
  if at == k_crc {
    c.byte() |> ignore
    let flags = c.booleans(count, true)
    for i in 0..<count {
      defined[i] = flags[i]
      if flags[i] {
        crcs[i] = c.u32le()
      }
    }
    at = c.peek()
  }
  if at != k_end {
    raise @moonzip.Header(
      at=c.at,
      what="a pack info that does not end where it should",
    )
  }
  c.byte() |> ignore
  { pos, sizes, crcs, defined, }
}

///|
fn read_unpack_info(c : Cursor) -> Array[Folder] raise @moonzip.Refused {
  if c.byte() != k_folder {
    raise @moonzip.Header(at=c.at, what="an unpack info without a folder table")
  }
  let count = c.uint64().to_int()
  if count < 0 || count > 65536 {
    raise @moonzip.Header(
      at=c.at,
      what="an archive with the wrong number of folders",
    )
  }
  let external = c.byte()
  if external != 0 {
    // A folder table stored in a stream rather than in the header. Legal, and
    // never written by anything that also writes a header this size.
    raise @moonzip.Header(
      at=c.at,
      what="a folder table kept in a separate stream, which is not implemented",
    )
  }
  let folders : Array[Folder] = []
  for _ in 0..<count {
    folders.push(read_folder(c))
  }
  if c.byte() != k_coders_unpack_size {
    raise @moonzip.Header(at=c.at, what="an unpack info without unpack sizes")
  }
  for folder in folders {
    for coder in folder.coders {
      for _ in 0..<coder.num_out {
        folder.unpack_sizes.push(c.uint64())
      }
    }
  }
  let mut next = c.peek()
  if next == k_crc {
    c.byte() |> ignore
    let flags = c.booleans(count, true)
    for i in 0..<count {
      if flags[i] {
        folders[i].crc = c.u32le()
        folders[i].crc_defined = true
      }
    }
    next = c.peek()
  }
  if next != k_end {
    raise @moonzip.Header(
      at=c.at,
      what="an unpack info that does not end where it should",
    )
  }
  c.byte() |> ignore
  folders
}

///|
fn read_sub_info(
  c : Cursor,
  folders : Array[Folder],
) -> SubInfo raise @moonzip.Refused {
  let count = folders.length()
  let counts = Array::make(count, 1)
  let sizes : Array[Int64] = []
  let crcs : Array[UInt32] = []
  let defined : Array[Bool] = []
  let mut next = c.peek()
  if next == k_num_unpack_stream {
    c.byte() |> ignore
    for i in 0..<count {
      let n = c.uint64().to_int()
      if n < 0 || n > 65536 {
        raise @moonzip.Header(at=c.at, what="a folder claiming too many files")
      }
      counts[i] = n
    }
    next = c.peek()
  }
  if next == k_size {
    c.byte() |> ignore
    for i in 0..<count {
      let mut total = 0L
      // All but the last are explicit; the last is what is left of the folder.
      for _ in 1..<counts[i] {
        let size = c.uint64()
        sizes.push(size)
        total = total + size
      }
      sizes.push(folder_size(folders[i]) - total)
    }
    next = c.peek()
  } else {
    for i in 0..<count {
      for _ in 0..<counts[i] {
        sizes.push(folder_size(folders[i]) / counts[i].to_int64())
      }
    }
  }
  next = c.peek()
  if next == k_crc {
    c.byte() |> ignore
    let flags = c.booleans(sizes.length(), true)
    for i in 0..<sizes.length() {
      defined.push(flags[i])
      crcs.push(if flags[i] { c.u32le() } else { 0U })
    }
    next = c.peek()
  } else {
    for _ in 0..<sizes.length() {
      defined.push(false)
      crcs.push(0U)
    }
  }
  if next != k_end {
    raise @moonzip.Header(
      at=c.at,
      what="substreams info that does not end where it should",
    )
  }
  c.byte() |> ignore
  { counts, sizes, crcs, defined, }
}

///|
/// What a folder expands to: the last coder's output.
fn folder_size(folder : Folder) -> Int64 {
  folder.unpack_sizes[folder.unpack_sizes.length() - 1]
}

///|
fn read_streams(c : Cursor) -> Streams raise @moonzip.Refused {
  let mut pack = None
  let folders : Array[Folder] = []
  let mut subs = None
  let mut next = c.peek()
  if next == k_pack_info {
    c.byte() |> ignore
    pack = Some(read_pack_info(c))
    next = c.peek()
  }
  if next == k_unpack_info {
    c.byte() |> ignore
    for folder in read_unpack_info(c) {
      folders.push(folder)
    }
    next = c.peek()
  }
  if next == k_substreams_info {
    c.byte() |> ignore
    subs = Some(read_sub_info(c, folders))
    next = c.peek()
  }
  if next != k_end {
    raise @moonzip.Header(
      at=c.at,
      what="streams info that does not end where it should",
    )
  }
  c.byte() |> ignore
  { pack, folders, subs, }
}

///|
/// The file table: names, which of them have no data, times and attributes.
///
/// Each property is a block with its own length, which is what makes this
/// parseable by skipping: a property this package does not understand can be
/// stepped over rather than guessed at.
fn read_files(
  c : Cursor,
  streams : Streams,
) -> Array[FileRec] raise @moonzip.Refused {
  let count = c.uint64().to_int()
  if count < 0 || count > 1048576 {
    raise @moonzip.Header(
      at=c.at,
      what="an archive with an impossible file count",
    )
  }
  // Built one at a time, not with `Array::make`: a record with mutable fields is
  // boxed, and filling an array with one of them gives every slot the *same*
  // box. The symptom is an archive whose every entry is the last one written.
  let files : Array[FileRec] = []
  for _ in 0..<count {
    files.push(FileRec::{
      name: "",
      empty_stream: false,
      empty_file: false,
      anti: false,
      mtime: 0L,
      attributes: 0U,
    })
  }
  let _ = streams
  let mut empty_count = 0
  while true {
    let id = c.peek()
    if id == k_end {
      c.byte() |> ignore
      break
    }
    if id == k_dummy {
      c.byte() |> ignore
      let size = c.uint64().to_int()
      c.take(size) |> ignore
      continue
    }
    c.byte() |> ignore
    let size = c.uint64().to_int()
    if size < 0 || c.left() < size {
      raise @moonzip.Truncated(at=c.at)
    }
    let block = Cursor::new(c.take(size))
    // A `match` arm written as a bare name is a *binding*, not a comparison, so
    // these have to be ifs: `match id { k_empty_stream => ... }` compiles and
    // silently matches every id.
    if id == k_empty_stream {
      let flags = block.booleans(count, false)
      empty_count = 0
      for i in 0..<count {
        files[i].empty_stream = flags[i]
        if flags[i] {
          empty_count += 1
        }
      }
    } else if id == k_empty_file {
      let flags = block.booleans(empty_count, false)
      let mut k = 0
      for i in 0..<count {
        if files[i].empty_stream {
          files[i].empty_file = flags[k]
          k += 1
        }
      }
    } else if id == k_anti {
      let flags = block.booleans(empty_count, false)
      let mut k = 0
      for i in 0..<count {
        if files[i].empty_stream {
          files[i].anti = flags[k]
          k += 1
        }
      }
    } else if id == k_name {
      if block.byte() != 0 {
        raise @moonzip.Header(
          at=block.at,
          what="names kept in a separate stream, which is not implemented",
        )
      }
      for i in 0..<count {
        // 7-Zip writes backslashes, because it is a Windows format that outgrew
        // Windows; the rest of the world wants the other one.
        files[i].name = block.utf16().replace(old="\\", new="/")
      }
    } else if id == k_mtime {
      let flags = block.booleans(count, true)
      let _ = block.byte()
      for i in 0..<count {
        if flags[i] {
          // A Windows FILETIME: hundreds of nanoseconds since 1601. Unix seconds
          // is that minus the epoch difference, divided by ten million.
          let stamp = block.u64le()
          files[i].mtime = stamp / 10000000L - 11644473600L
        }
      }
    } else if id == k_attributes {
      let flags = block.booleans(count, true)
      let _ = block.byte()
      for i in 0..<count {
        if flags[i] {
          files[i].attributes = block.u32le()
        }
      }
    }
    // Every other property has already been stepped over by its length, which is
    // the point of a property that declares its own size.
  }
  files
}

// ------------------------------------------------------------------- the coders

///|
/// Apply one coder to a stream, producing exactly `want` bytes.
fn apply_coder(
  coder : Coder,
  data : BytesView,
  want : Int64,
  limit : Int32,
) -> Bytes raise @moonzip.Refused {
  let codec = coder.codec
  let bound = if want > 2147483647L { 2147483647 } else { want.to_int() }
  let effective = if limit >= 0 && bound > limit { limit } else { bound }
  if codec.length() == 1 && codec[0] == 0x00 {
    // Copy: the "compression" that only exists so a folder can be uniform.
    if data.length().to_int64() != want {
      raise @moonzip.Length(
        want=want.to_int().reinterpret_as_uint(),
        got=data.length(),
      )
    }
    return data.to_owned()
  }
  if codec.length() == 3 &&
    codec[0] == 0x03 &&
    codec[1] == 0x01 &&
    codec[2] == 0x01 {
    if coder.props.length() < 5 {
      raise @moonzip.Header(
        at=0,
        what="an LZMA coder without its five property bytes",
      )
    }
    let decoder = @lzma.Decoder::new(limit=effective)
    decoder.properties(coder.props[0].to_int())
    decoder.feed(data, bound) |> ignore
    let made = decoder.output()
    if made.length().to_int64() != want {
      raise @moonzip.Length(
        want=want.to_int().reinterpret_as_uint(),
        got=made.length(),
      )
    }
    return made
  }
  if codec.length() == 1 && codec[0] == 0x21 {
    let decoder = @lzma.Decoder::new(limit=effective)
    let made = @lzma.unlzma2(data, 0, decoder)
    if made.0.length().to_int64() != want {
      raise @moonzip.Length(
        want=want.to_int().reinterpret_as_uint(),
        got=made.0.length(),
      )
    }
    return made.0
  }
  if codec.length() == 3 &&
    codec[0] == 0x04 &&
    codec[1] == 0x02 &&
    codec[2] == 0x02 {
    let made = @bzip2.bunzip2(data, limit=effective)
    if made.length().to_int64() != want {
      raise @moonzip.Length(
        want=want.to_int().reinterpret_as_uint(),
        got=made.length(),
      )
    }
    return made
  }
  if codec.length() == 3 &&
    codec[0] == 0x04 &&
    codec[1] == 0x01 &&
    codec[2] == 0x08 {
    let made = @deflate.inflate(data, limit=effective)
    if made.length().to_int64() != want {
      raise @moonzip.Length(
        want=want.to_int().reinterpret_as_uint(),
        got=made.length(),
      )
    }
    return made
  }
  if codec.length() == 1 && codec[0] == 0x03 {
    // Delta: each byte is the difference from the one `distance` back. It is a
    // filter, not a compressor, and it exists because a delta of a table of
    // little-endian numbers is almost all zeros.
    let distance = if coder.props.length() > 0 {
      coder.props[0].to_int() + 1
    } else {
      1
    }
    let made : Array[Byte] = []
    for i in 0..<data.length() {
      let back = if i >= distance { made[i - distance].to_int() } else { 0 }
      made.push(((data[i].to_int() + back) & 0xFF).to_byte())
    }
    return Bytes::from_array(made)
  }
  raise @moonzip.Header(
    at=0,
    what="a compression method this package does not implement (\{method_label(codec)})",
  )
}

///|
/// A coder id as the specification writes it: the bytes in order, in hex.
fn method_label(codec : Array[Int32]) -> String {
  let out = StringBuilder()
  for i in 0..<codec.length() {
    if i > 0 {
      out.write_string(" ")
    }
    let byte = codec[i]
    let high = byte / 16
    let low = byte % 16
    out.write_char(hex_digit(high))
    out.write_char(hex_digit(low))
  }
  out.to_string()
}

///|
fn hex_digit(value : Int32) -> Char {
  if value < 10 {
    (48 + value).unsafe_to_char()
  } else {
    (87 + value).unsafe_to_char()
  }
}

///|
/// Run a folder's chain over its packed bytes.
fn decode_folder(
  folder : Folder,
  packed : BytesView,
  limit : Int32,
) -> Bytes raise @moonzip.Refused {
  let mut current = packed.to_owned()
  for i in 0..<folder.coders.length() {
    let want = if i < folder.unpack_sizes.length() {
      folder.unpack_sizes[i]
    } else {
      current.length().to_int64()
    }
    current = apply_coder(folder.coders[i], current[:], want, limit)
  }
  current
}
