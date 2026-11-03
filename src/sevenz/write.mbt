// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How the writer compresses. 7z is a container, so this is a choice rather than
/// a property of the format: the same archive can hold a folder of LZMA and a
/// folder of copies.
pub(all) enum Method {
  /// Nothing at all. The folder exists so the file table has something to point
  /// at, which is what makes a `.7z` a `.7z` even uncompressed.
  Copy
  /// LZMA, which is what 7-Zip's own default is for text.
  Lzma
  /// LZMA2, the chunked form. Same codec, resettable state.
  Lzma2
} derive(Eq, Debug)

///|
pub extend Method with Eq::{equal, not_equal}

///|
pub extend Method with Debug::{to_repr}

///|
/// The name a log line wants.
pub fn Method::label(self : Method) -> String {
  match self {
    Copy => "copy"
    Lzma => "lzma"
    Lzma2 => "lzma2"
  }
}

///|
/// One folder ready to be written: its packed bytes, and what it expands to.
priv struct Packed {
  coder : Coder
  data : Bytes
  unpacked : Int64
}

///|
/// Build a 7z archive.
///
/// ```moonbit nocheck
/// let archive = @sevenz.sevenz(members[:], level=6)
/// ```
///
/// `solid` is 7-Zip's own default and the format's reason for existing: one
/// folder holds every file, so the compressor sees them all at once and a
/// repeated phrase across two files is paid for once. The cost is that reading
/// the last file means decompressing the first ones, which is why it is an
/// argument.
pub fn sevenz(
  entries : ArrayView[Entry],
  level~ : Int32 = 6,
  how~ : Method = Lzma,
  solid~ : Bool = true,
) -> Bytes {
  let writer = Writer::new(level~, how~, solid~)
  let body : Array[Byte] = []
  for i in 0..<entries.length() {
    for b in writer.add(entries[i]) {
      body.push(b)
    }
  }
  // The directory and the signature header describe what the folders turned
  // out to be, so both are made once every entry has been written.
  let tail = writer.finish()
  let start = writer.signature()
  let out : Array[Byte] = []
  for b in start {
    out.push(b)
  }
  for b in body {
    out.push(b)
  }
  for b in tail {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
fn folders_data_size(folders : Array[Packed]) -> Int64 {
  let mut total = 0L
  for folder in folders {
    total = total + folder.data.length().to_int64()
  }
  total
}

///|
fn le32(value : UInt32) -> Array[Byte] {
  let out : Array[Byte] = []
  for i in 0..<4 {
    out.push(((value >> (i * 8)) & 0xFFU).reinterpret_as_int().to_byte())
  }
  out
}

///|
fn le64(value : Int64) -> Array[Byte] {
  let out : Array[Byte] = []
  for i in 0..<8 {
    out.push(((value >> (i * 8)) & 0xFFL).to_int().to_byte())
  }
  out
}

///|
/// The directory.
///
/// Written uncompressed, which is the one place this writer takes the simple
/// road: 7-Zip compresses the header too once there are enough entries for it to
/// pay. A reader has to handle both, and the one it can always produce is the
/// one a writer should emit when the size does not matter.
fn build_header(
  entries : ArrayView[Entry],
  blanks : Array[Bool],
  folders : Array[Packed],
  counts : Array[Int32],
  sizes : Array[Int64],
  crcs : Array[UInt32],
) -> Bytes {
  let out = Put::new()
  out.byte(k_header)
  if folders.length() > 0 {
    out.byte(k_main_streams)
    // Pack info: where the packed streams are, and how long each is.
    out.byte(k_pack_info)
    out.uint64(0L)
    out.uint64(folders.length().to_int64())
    out.byte(k_size)
    for folder in folders {
      out.uint64(folder.data.length().to_int64())
    }
    out.byte(k_end)
    // Unpack info: the coders and the sizes they produce.
    out.byte(k_unpack_info)
    out.byte(k_folder)
    out.uint64(folders.length().to_int64())
    out.byte(0)
    for folder in folders {
      out.uint64(1L)
      let coder = folder.coder
      let flag = coder.codec.length() |
        (if coder.props.length() > 0 { 0x20 } else { 0x00 })
      out.byte(flag)
      for b in coder.codec {
        out.byte(b)
      }
      if coder.props.length() > 0 {
        out.uint64(coder.props.length().to_int64())
        out.bytes(coder.props[:])
      }
    }
    out.byte(k_coders_unpack_size)
    for folder in folders {
      out.uint64(folder.unpacked)
    }
    out.byte(k_end)
    // Substreams, only when a folder holds more than one file. A folder with one
    // file needs nothing here: its size and checksum are already above.
    let multi = has_multi(counts)
    if multi {
      out.byte(k_substreams_info)
      out.byte(k_num_unpack_stream)
      for n in counts {
        out.uint64(n.to_int64())
      }
      out.byte(k_size)
      let mut index = 0
      for f in 0..<counts.length() {
        // All but the last size of a folder are written; the last is the
        // remainder, which the reader computes from the folder's own size.
        for _ in 1..<counts[f] {
          out.uint64(sizes[index])
          index += 1
        }
        index += 1
      }
      out.byte(k_crc)
      let defined : Array[Bool] = []
      for _ in 0..<crcs.length() {
        defined.push(true)
      }
      out.booleans(defined, true)
      for crc in crcs {
        out.u32le(crc)
      }
      out.byte(k_end)
    }
    out.byte(k_end)
  }
  // The file table.
  out.byte(k_files_info)
  out.uint64(entries.length().to_int64())
  let empty_stream : Array[Bool] = []
  let empty_file : Array[Bool] = []
  for i in 0..<entries.length() {
    // Whether a member has data is the caller's to say: the directory is built
    // from the names and times the writer was given, at a point where the data
    // itself has long been compressed and let go.
    let blank = blanks[i]
    empty_stream.push(blank)
    empty_file.push(blank && entries[i].kind == File)
  }
  if any(empty_stream) {
    out.byte(k_empty_stream)
    let block = Put::new()
    block.booleans(empty_stream, false)
    let made = block.finish()
    out.uint64(made.length().to_int64())
    out.bytes(made[:])
  }
  if any(empty_file) {
    let only : Array[Bool] = []
    for i in 0..<entries.length() {
      if empty_stream[i] {
        only.push(empty_file[i])
      }
    }
    out.byte(k_empty_file)
    let block = Put::new()
    block.booleans(only, false)
    let made = block.finish()
    out.uint64(made.length().to_int64())
    out.bytes(made[:])
  }
  out.byte(k_name)
  let names = Put::new()
  names.byte(0)
  for entry in entries {
    names.utf16(entry.name)
  }
  let name_bytes = names.finish()
  out.uint64(name_bytes.length().to_int64())
  out.bytes(name_bytes[:])
  // Modification time, as the FILETIME 7-Zip stores.
  out.byte(k_mtime)
  let times = Put::new()
  let defined : Array[Bool] = []
  for entry in entries {
    defined.push(entry.mtime != 0L)
  }
  times.booleans(defined, true)
  times.byte(0)
  for i in 0..<entries.length() {
    if defined[i] {
      times.u64le((entries[i].mtime + 11644473600L) * 10000000L)
    }
  }
  let time_bytes = times.finish()
  out.uint64(time_bytes.length().to_int64())
  out.bytes(time_bytes[:])
  // Attributes, which is where "directory" lives.
  out.byte(k_attributes)
  let attrs = Put::new()
  attrs.booleans(defined_all(entries), true)
  attrs.byte(0)
  for entry in entries {
    attrs.u32le(
      if entry.kind == Directory {
        0x10U
      } else if entry.attributes != 0U {
        entry.attributes
      } else {
        0x20U
      },
    )
  }
  let attr_bytes = attrs.finish()
  out.uint64(attr_bytes.length().to_int64())
  out.bytes(attr_bytes[:])
  out.byte(k_end)
  out.byte(k_end)
  out.finish()
}

///|
fn has_multi(counts : Array[Int32]) -> Bool {
  let mut seen = false
  for n in counts {
    if n > 1 {
      seen = true
    }
  }
  seen
}

///|
fn any(flags : Array[Bool]) -> Bool {
  let mut seen = false
  for f in flags {
    if f {
      seen = true
    }
  }
  seen
}

///|
fn defined_all(entries : ArrayView[Entry]) -> Array[Bool] {
  let out : Array[Bool] = []
  for _ in 0..<entries.length() {
    out.push(true)
  }
  out
}
