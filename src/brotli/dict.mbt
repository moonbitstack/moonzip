// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The static dictionary and the 121 ways brotli may bend a word out of it.
///
/// When a copy's distance is larger than the window it is not a back-reference
/// at all: it is `(word length, word index, transform)` packed into one number.
/// The word comes from a 122,784-byte blob of the 13,504 most common words in
/// several languages, laid out in 25 buckets by length, and the transform is what
/// turns `time` into `Time`, `time`, `time's`, `timed`, `timely` and so on.
///
/// This is the part of brotli that a decoder cannot fake and cannot skip. A
/// reader without the blob decodes every stream correctly until the first
/// dictionary reference, then emits the wrong bytes and keeps going — which is
/// the failure mode worth spending 120 kilobytes to avoid.
///
/// The buckets, from the reference: `size_bits_by_length[l]` is how many bits of
/// the address select the word, `offsets_by_length[l]` is where bucket `l` starts.
let dict_bits : FixedArray[Int32] = [
  0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5,
  5, 0, 0, 0, 0, 0, 0, 0,
]

///|
let dict_offset : FixedArray[Int32] = [
  0, 0, 0, 0, 0, 4096, 9216, 21504, 35840, 44032, 53248, 63488, 74752, 87040, 93696,
  100864, 104704, 106752, 108928, 113536, 115968, 118528, 119872, 121280, 122016,
  122784, 122784, 122784, 122784, 122784, 122784, 122784,
]

///|
/// How many transforms the table holds. An address that asks for a 122nd is not
/// a dictionary reference, it is damage.
const TRANSFORM_COUNT : Int32 = 121

///|
/// Uppercase one character in place, `p[0]` being its first byte.
///
/// The reference is deliberately ASCII-first and approximate above it: a
/// two-byte character has bit 5 of its second byte flipped, a three-byte one has
/// bit 2 of its third byte flipped. That is not Unicode case mapping, and it is
/// not meant to be — it only has to agree with the encoder that wrote the
/// reference, and the encoder uses the same table.
fn uppercase(word : Array[Byte], at : Int32, end : Int32) -> Int32 {
  if at >= end {
    return 1
  }
  let first = word[at].to_int()
  if first < 0xC0 {
    if first >= 0x61 && first <= 0x7A {
      word[at] = (first ^ 32).to_byte()
    }
    return 1
  }
  if first < 0xE0 {
    if at + 1 < end {
      word[at + 1] = (word[at + 1].to_int() ^ 32).to_byte()
    }
    return 2
  }
  if at + 2 < end {
    word[at + 2] = (word[at + 2].to_int() ^ 5).to_byte()
  }
  return 3
}

///|
/// Apply transform `transform` to a dictionary word, appending the result.
///
/// The transform is a triple: a prefix fragment, one of 23 edits to the word,
/// and a suffix fragment. Fragments are length-prefixed strings in a single
/// 217-byte table, reached through `prefix_suffix_map`.
fn transform_word(
  word : FixedArray[Byte],
  length : Int32,
  transform : Int32,
  out : Array[Byte],
) -> Unit {
  // Three lookups, not two: the transform table holds *fragment ids*, and the
  // map turns an id into an offset in the fragment blob. Indexing the map with
  // the transform's own position reads past its fifty entries.
  let prefix = prefix_suffix_map[transforms[transform * 3]]
  let kind = transforms[transform * 3 + 1]
  let suffix = prefix_suffix_map[transforms[transform * 3 + 2]]
  let mut start = 0
  let mut stop = length
  if kind >= 1 && kind <= 9 {
    stop -= kind
  } else if kind >= 12 && kind <= 20 {
    start += kind - 11
  }
  let count = prefix_suffix[prefix].to_int()
  for i in 0..<count {
    out.push(prefix_suffix[prefix + 1 + i])
  }
  let base = out.length()
  if stop > start {
    for i in start..<stop {
      out.push(word[i])
    }
  }
  let copied = out.length() - base
  if kind == 10 {
    let _ = uppercase(out, base, base + copied)
  } else if kind == 11 {
    let mut at = base
    while at < base + copied {
      at += uppercase(out, at, base + copied)
    }
  }
  // Transform 21 and 22 (`SHIFT_FIRST`, `SHIFT_ALL`) need a parameter table the
  // standard dictionary does not ship, so they cannot occur; the reference would
  // dereference a null pointer here rather than fail.
  let count = prefix_suffix[suffix].to_int()
  for i in 0..<count {
    out.push(prefix_suffix[suffix + 1 + i])
  }
}

///|
/// Decode one dictionary reference: the copy length picks the bucket, the address
/// splits into a word index and a transform index.
fn dictionary_word(
  distance : Int32,
  max_distance : Int32,
  length : Int32,
  out : Array[Byte],
) -> Unit raise @moonzip.Refused {
  if length < 4 || length > 24 {
    raise @moonzip.Header(
      at=out.length(),
      what="a dictionary reference of \{length} bytes, and none that length exists",
    )
  }
  let shift = dict_bits[length]
  if shift == 0 {
    raise @moonzip.Header(
      at=out.length(),
      what="a dictionary bucket that is empty",
    )
  }
  let address = distance - max_distance - 1
  let index = address & ((1 << shift) - 1)
  let transform = address >> shift
  if transform >= TRANSFORM_COUNT {
    raise @moonzip.Header(
      at=out.length(),
      what="transform \{transform} of \{TRANSFORM_COUNT}",
    )
  }
  let offset = dict_offset[length] + index * length
  let word = FixedArray::make(length, b'\x00')
  for i in 0..<length {
    word[i] = dictionary[offset + i]
  }
  if transform == 0 {
    for i in 0..<length {
      out.push(word[i])
    }
  } else {
    transform_word(word, length, transform, out)
  }
}
