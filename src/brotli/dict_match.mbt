// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Finding the static dictionary's words in the text being compressed.
///
/// A dictionary reference is not a back-reference: the distance is larger than
/// the window, and what it addresses is `(transform, word)` inside the 122 KB
/// blob rather than a byte of the output. So the encoder has to answer a
/// different question from the one a match finder answers — not "where did I see
/// these bytes before" but "is this one of the words the format already knows" —
/// and the answer has to come with the word's length, which is also the copy's
/// length.
///
/// The index here is over first four bytes and is built once per `compress` call:
/// thirteen thousand words hashed into sixty-five thousand buckets, then a walk
/// down one chain per position. Four bytes because a dictionary reference shorter
/// than four is not representable.
const DICT_HASH_BITS : Int32 = 16

///|
/// The two transforms this writer emits.
///
/// The format has 121, and the rest are suffix and prefix surgery — `-s`, `-ed`,
/// `-ing`, `un-` — which change the word's length and so the copy's. Identity and
/// "uppercase the first letter" are the two that leave the word the length the
/// text spells it, which is what makes them cheap to search for: one hash probe
/// each, and the sentence-initial `Time` costs the same code as `time`.
///
/// The uppercase id is **looked up, not assumed**. The transform table is a
/// transcription of the reference's own ordering, which is not the ordering of
/// the `BROTLI_TRANSFORM_*` enum that names them — id 10 in the table is a suffix
/// transform, and the plain uppercase-first is id 9. Writing the constant the
/// other way produced a stream that matched at encode time and decoded to
/// lowercase, so the id is found by shape instead: the entry whose kind is
/// "uppercase first" and whose prefix and suffix are both empty.
const TRANSFORM_IDENTITY : Int32 = 0

///|
const TRANSFORM_UPPERCASE_KIND : Int32 = 10

///|
/// Is this fragment id the empty fragment?
fn fragment_is_empty(id : Int32) -> Bool {
  prefix_suffix[prefix_suffix_map[id]].to_int() == 0
}

///|
/// The id of the plain uppercase-first transform, or -1 if the table has none.
fn uppercase_first_id() -> Int32 {
  for t in 0..<TRANSFORM_COUNT {
    if transforms[t * 3 + 1] == TRANSFORM_UPPERCASE_KIND &&
      fragment_is_empty(transforms[t * 3]) &&
      fragment_is_empty(transforms[t * 3 + 2]) {
      return t
    }
  }
  -1
}

///|
/// A hash of four bytes, wrapping on purpose.
fn dict_key(b0 : Int32, b1 : Int32, b2 : Int32, b3 : Int32) -> Int32 {
  let h = (b0 * 0x1F1F1F1F) ^
    (b1 * 0x3B9ACA07) ^
    (b2 * 0x27D4EB2D) ^
    (b3 * 0x165667B1)
  h & 0xFFFF & ((1 << DICT_HASH_BITS) - 1)
}

///|
/// Lowercase one byte if it is a letter, which is what makes a sentence-initial
/// capital findable.
fn dict_lower(b : Int32) -> Int32 {
  if b >= 0x61 && b <= 0x7A {
    b
  } else if b >= 0x41 && b <= 0x5A {
    b + 32
  } else {
    b
  }
}

///|
/// Upper the same way, so a word's first letter can be checked against a capital
/// the text actually used.
fn dict_upper(b : Int32) -> Int32 {
  if b >= 0x61 && b <= 0x7A {
    b - 32
  } else {
    b
  }
}

///|
/// The dictionary, indexed for lookup by first four bytes.
priv struct DictIndex {
  heads : FixedArray[Int32]
  next : FixedArray[Int32]
  lens : FixedArray[Int32]
  slots : FixedArray[Int32]
  capital : Int32
}

///|
fn DictIndex::build() -> DictIndex {
  let mut words = 0
  for len in 4..<25 {
    words += 1 << dict_bits[len]
  }
  let heads = FixedArray::make(1 << DICT_HASH_BITS, -1)
  let next = FixedArray::make(words, -1)
  let lens = FixedArray::make(words, 0)
  let slots = FixedArray::make(words, 0)
  let mut ordinal = 0
  for len in 4..<25 {
    let count = 1 << dict_bits[len]
    for slot in 0..<count {
      let at = dict_offset[len] + slot * len
      let key = dict_key(
        dictionary[at].to_int(),
        dictionary[at + 1].to_int(),
        dictionary[at + 2].to_int(),
        dictionary[at + 3].to_int(),
      )
      next[ordinal] = heads[key]
      heads[key] = ordinal
      lens[ordinal] = len
      slots[ordinal] = slot
      ordinal += 1
    }
  }
  { heads, next, lens, slots, capital: uppercase_first_id(), }
}

///|
/// Does dictionary word `slot` of length `len` spell the input at `at`?
///
/// `capital` asks for the uppercase-first transform, which is the identity
/// compared byte for byte except that the first letter of the input has to be the
/// capital of the word's.
fn dict_spells(
  data : BytesView,
  at : Int32,
  len : Int32,
  slot : Int32,
  capital : Bool,
) -> Bool {
  let base = dict_offset[len] + slot * len
  for i in 0..<len {
    let word = dictionary[base + i].to_int()
    let seen = data[at + i].to_int()
    let want = if i == 0 && capital { dict_upper(word) } else { word }
    if seen != want {
      return false
    }
  }
  true
}

///|
/// The longest dictionary word starting at `at`, as `(length, slot, transform)`.
///
/// A length of zero means the dictionary has nothing here, which is the answer for
/// most positions and costs one hash probe.
fn DictIndex::find(
  self : DictIndex,
  data : BytesView,
  at : Int32,
  end : Int32,
) -> (Int32, Int32, Int32) {
  let room = end - at
  if room < 4 {
    return (0, 0, 0)
  }
  let first = data[at].to_int()
  let second = data[at + 1].to_int()
  let third = data[at + 2].to_int()
  let fourth = data[at + 3].to_int()
  let mut best = 0
  let mut best_slot = 0
  let mut best_transform = TRANSFORM_IDENTITY
  let mut probe = 0
  while probe < 2 {
    let head = if probe == 0 { first } else { dict_lower(first) }
    // The second probe is skipped when the table has no uppercase transform, and
    // when the first byte has no case — then it would repeat the first probe.
    if probe == 0 || (self.capital >= 0 && head != first) {
      let mut ordinal = self.heads[dict_key(head, second, third, fourth)]
      while ordinal >= 0 {
        let len = self.lens[ordinal]
        if len > best && len <= room {
          let slot = self.slots[ordinal]
          let capital = probe == 1
          if dict_spells(data, at, len, slot, capital) {
            best = len
            best_slot = slot
            best_transform = if capital {
              self.capital
            } else {
              TRANSFORM_IDENTITY
            }
          }
        }
        ordinal = self.next[ordinal]
      }
    }
    probe += 1
  }
  (best, best_slot, best_transform)
}

///|
/// The address a dictionary reference carries: the transform above the bits that
/// select the word, which is the inverse of what `dictionary_word` reads.
fn DictIndex::address(len : Int32, slot : Int32, transform : Int32) -> Int32 {
  (transform << dict_bits[len]) | slot
}
